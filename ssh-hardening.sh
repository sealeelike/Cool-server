#!/usr/bin/env bash
# ssh-hardening.sh — Debian/Ubuntu VPS SSH 安全加固脚本
# 支持远程执行：curl -sSL https://raw.githubusercontent.com/sealeelike/Cool-server/main/ssh-hardening.sh | bash
set -euo pipefail

# ─────────────────────────────────────────────
# 颜色 & 图标
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

OK="  ${GREEN}✅${RESET}"
FAIL="  ${RED}❌${RESET}"
WARN="  ${YELLOW}⚠️ ${RESET}"
INFO="  ${CYAN}ℹ️ ${RESET}"

print_phase() {
  echo ""
  echo -e "${BOLD}${CYAN}$1${RESET}"
  echo -e "${CYAN}$(printf '─%.0s' {1..50})${RESET}"
}

ok()   { echo -e "${OK} $*"; }
fail() { echo -e "${FAIL} $*"; }
warn() { echo -e "${WARN} $*"; }
info() { echo -e "${INFO} $*"; }

die() {
  echo -e "${FAIL} ${RED}$*${RESET}" >&2
  exit 1
}

confirm() {
  local prompt="${1:-继续？(y/n): }"
  local answer
  read -r -p "$(echo -e "  ${YELLOW}${prompt}${RESET}")" answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ─────────────────────────────────────────────
# 运行命令（带错误捕获，不受 set -e 影响）
# ─────────────────────────────────────────────
run() {
  if "$@" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# ─────────────────────────────────────────────
# 提权辅助
# ─────────────────────────────────────────────
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
fi

privileged() {
  $SUDO "$@"
}

# ─────────────────────────────────────────────
# 阶段一：预检查
# ─────────────────────────────────────────────
phase_precheck() {
  print_phase "[阶段 1/3] 预检查"

  # 1. root 或 sudo
  if [[ "$(id -u)" -eq 0 ]]; then
    ok "检测到 root 权限"
  elif run sudo -n true; then
    ok "检测到 sudo 权限"
    SUDO="sudo"
  else
    fail "需要 root 权限或 sudo 权限，请切换到 root 用户后重试"
    exit 1
  fi

  # 2. 系统检测
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID:-}" in
      debian|ubuntu)
        ok "系统: ${PRETTY_NAME:-${ID}}"
        ;;
      *)
        warn "当前系统为 ${PRETTY_NAME:-未知}，本脚本针对 Debian/Ubuntu 优化，继续可能出现兼容问题"
        confirm "仍要继续？(y/n): " || exit 0
        ;;
    esac
  else
    warn "无法识别系统版本，继续执行"
  fi

  # 3. sshd include 目录
  if grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
    ok "sshd 支持 include 目录 (/etc/ssh/sshd_config.d/)"
    SSHD_CONF_DIR="/etc/ssh/sshd_config.d"
  else
    warn "sshd_config 中未找到 Include 指令，将直接修改 /etc/ssh/sshd_config"
    SSHD_CONF_DIR=""
  fi

  # 4. fail2ban
  if command -v fail2ban-client >/dev/null 2>&1; then
    ok "fail2ban 已安装"
    F2B_INSTALLED=true
  else
    warn "fail2ban 未安装（将在阶段三自动安装）"
    F2B_INSTALLED=false
  fi

  # 5. 当前 SSH 配置摘要
  echo ""
  info "当前 SSH 配置摘要："
  for key in PubkeyAuthentication PasswordAuthentication PermitRootLogin; do
    val=$(privileged sshd -T 2>/dev/null | grep -i "^${key} " | awk '{print $2}' || echo "未知")
    printf "     %-35s %s\n" "${key}:" "${val}"
  done
}

# ─────────────────────────────────────────────
# 阶段二：公钥配置
# ─────────────────────────────────────────────
phase_pubkey() {
  print_phase "[阶段 2/3] 公钥配置"

  # 确定目标用户
  if [[ "$(id -u)" -eq 0 ]]; then
    TARGET_USER="root"
    TARGET_HOME="/root"
  else
    TARGET_USER="$(id -un)"
    TARGET_HOME="$HOME"
  fi

  SSH_DIR="${TARGET_HOME}/.ssh"
  AUTH_KEYS="${SSH_DIR}/authorized_keys"

  # 读取公钥
  echo ""
  echo -e "  ${YELLOW}请输入您的 SSH 公钥（ssh-ed25519 或 ssh-rsa 开头，整行粘贴后回车）:${RESET}"
  local pubkey=""
  local tmpkey
  tmpkey=$(mktemp)
  while true; do
    read -r -p "  > " pubkey
    if [[ "$pubkey" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]] ]]; then
      # 使用 ssh-keygen 进一步验证公钥格式
      printf '%s\n' "$pubkey" > "$tmpkey"
      if ssh-keygen -l -f "$tmpkey" >/dev/null 2>&1; then
        break
      else
        warn "公钥内容无效，请检查并重新粘贴完整公钥"
      fi
    else
      warn "公钥格式不正确，请重新输入（应以 ssh-ed25519、ssh-rsa 等开头）"
    fi
  done
  rm -f "$tmpkey"

  # 创建 .ssh 目录
  if [[ ! -d "$SSH_DIR" ]]; then
    mkdir -p "$SSH_DIR"
    ok "已创建目录 ${SSH_DIR}"
  fi
  chmod 700 "$SSH_DIR"

  # 写入 authorized_keys（避免重复写入，按公钥 material 比对）
  local pubkey_material
  pubkey_material=$(awk '{print $2}' <<< "$pubkey")
  if [[ -s "$AUTH_KEYS" ]] && awk '{print $2}' "$AUTH_KEYS" 2>/dev/null | grep -qxF "$pubkey_material"; then
    warn "公钥已存在于 ${AUTH_KEYS}，跳过写入"
  else
    echo "$pubkey" >> "$AUTH_KEYS"
    ok "公钥已写入 ${AUTH_KEYS}"
  fi
  chmod 600 "$AUTH_KEYS"
  ok "权限已设置: ${SSH_DIR} (700), ${AUTH_KEYS} (600)"

  # 启用 PubkeyAuthentication
  _enable_pubkey_auth
  ok "PubkeyAuthentication 已启用"

  # 重启 SSH
  _restart_ssh
  ok "SSH 服务已重启"

  # 提示用户测试
  echo ""
  echo -e "${YELLOW}  ─────────────────────────────────────────────${RESET}"
  warn "请在【新终端】测试公钥登录，成功后再继续！"
  echo ""
  echo -e "  Windows PowerShell 示例："
  echo -e "  ${CYAN}ssh -i C:\\Users\\你的用户名\\.ssh\\id_ed25519 ${TARGET_USER}@你的服务器IP${RESET}"
  echo ""
  echo -e "  Linux / macOS 示例："
  echo -e "  ${CYAN}ssh -i ~/.ssh/id_ed25519 ${TARGET_USER}@你的服务器IP${RESET}"
  echo -e "${YELLOW}  ─────────────────────────────────────────────${RESET}"
  echo ""

  confirm "公钥登录测试成功了吗？(y/n): " \
    || { warn "请先确认公钥登录成功后再继续，脚本已退出"; exit 0; }

  ok "用户已确认公钥登录成功，继续安全加固"
}

_enable_pubkey_auth() {
  if [[ -n "$SSHD_CONF_DIR" ]]; then
    local conf="${SSHD_CONF_DIR}/10-pubkey.conf"
    if [[ ! -f "$conf" ]] || ! grep -qE '^\s*PubkeyAuthentication\s+yes' "$conf" 2>/dev/null; then
      echo "PubkeyAuthentication yes" | privileged tee "$conf" >/dev/null
    fi
  else
    _set_sshd_option "PubkeyAuthentication" "yes" /etc/ssh/sshd_config
  fi
  privileged sshd -t || die "sshd 配置检查失败，请手动排查"
}

_restart_ssh() {
  if run privileged systemctl restart ssh 2>/dev/null; then
    return 0
  elif run privileged systemctl restart sshd 2>/dev/null; then
    return 0
  else
    die "无法重启 SSH 服务，请手动执行: systemctl restart ssh"
  fi
}

# 修改或追加 sshd_config 中的指令（直接编辑主配置时使用）
_set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="$3"
  # 转义 value 中的 sed 特殊字符（| & \ 以及界定符本身）
  local escaped_value
  escaped_value=$(printf '%s' "$value" | sed 's/[\\|&]/\\&/g')
  # 匹配行首可选注释符及空白，后跟精确的 key 词（单词边界用 \b 或空白/行尾保证）
  if privileged grep -qiE "^\s*#?\s*${key}(\s|$)" "$file" 2>/dev/null; then
    privileged sed -i -E "s|^(\s*#?\s*)${key}(\s.*)?$|${key} ${escaped_value}|I" "$file"
  else
    printf '%s %s\n' "$key" "$value" | privileged tee -a "$file" >/dev/null
  fi
}

# ─────────────────────────────────────────────
# 阶段三：安全加固
# ─────────────────────────────────────────────
phase_harden() {
  print_phase "[阶段 3/3] 安全加固"

  # 3.1 禁用密码登录
  _write_security_conf
  ok "已写入安全配置（禁用密码登录，允许 root 公钥）"

  privileged sshd -t || die "sshd 配置检查失败，请手动排查"
  _restart_ssh
  ok "SSH 服务已重启，密码登录已禁用"

  # 3.2 安装 fail2ban
  if [[ "$F2B_INSTALLED" == false ]]; then
    info "正在更新软件包索引..."
    privileged apt-get update -qq
    info "正在安装 fail2ban..."
    privileged apt-get install -y fail2ban
    ok "fail2ban 安装完成"
  fi

  privileged systemctl enable fail2ban >/dev/null 2>&1
  ok "fail2ban 已设置为开机自启"

  # 3.3 写入 jail.local
  _write_fail2ban_config
  ok "fail2ban jail.local 配置已写入"

  # 3.4 检测 & 重启 fail2ban
  if privileged fail2ban-client -t; then
    ok "fail2ban 配置检查通过"
  else
    fail "fail2ban 配置检查失败，请查看 /etc/fail2ban/jail.local"
  fi

  privileged systemctl restart fail2ban
  ok "fail2ban 服务已重启"

  echo ""
  info "最终状态验证："
  privileged fail2ban-client status 2>/dev/null || warn "无法获取 fail2ban 状态"
}

_write_security_conf() {
  if [[ -n "$SSHD_CONF_DIR" ]]; then
    privileged tee "${SSHD_CONF_DIR}/20-security.conf" >/dev/null <<'EOF'
# 只允许公钥认证
PubkeyAuthentication yes
AuthenticationMethods publickey

# 禁止密码认证
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no

# 允许 root 但仅公钥
PermitRootLogin prohibit-password
EOF
  else
    local cfg=/etc/ssh/sshd_config
    _set_sshd_option "PubkeyAuthentication"            "yes"               "$cfg"
    _set_sshd_option "AuthenticationMethods"           "publickey"         "$cfg"
    _set_sshd_option "PasswordAuthentication"          "no"                "$cfg"
    _set_sshd_option "ChallengeResponseAuthentication" "no"                "$cfg"
    _set_sshd_option "KbdInteractiveAuthentication"    "no"                "$cfg"
    _set_sshd_option "PermitEmptyPasswords"            "no"                "$cfg"
    _set_sshd_option "PermitRootLogin"                 "prohibit-password" "$cfg"
  fi
}

_write_fail2ban_config() {
  privileged tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[DEFAULT]

backend = systemd
bantime = 30m
findtime = 10m
maxretry = 5
banaction = iptables-multiport
logtarget = /var/log/fail2ban.log


[sshd]
enabled = true
port = ssh
filter = sshd


[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
findtime = 24h
maxretry = 5
bantime = 7d
EOF
}

# ─────────────────────────────────────────────
# 收尾
# ─────────────────────────────────────────────
phase_finish() {
  echo ""
  echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${RESET}"
  echo -e "${GREEN}${BOLD}  🎉 SSH 安全加固完成！${RESET}"
  echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${RESET}"
  echo ""
  echo -e "  ✔ 只允许公钥登录"
  echo -e "  ✔ root 仅允许公钥"
  echo -e "  ✔ 密码登录已禁用"
  echo -e "  ✔ SSH 爆破自动封禁 (30 分钟)"
  echo -e "  ✔ 累犯封 7 天 (recidive)"
  echo ""

  # 询问是否删除脚本自身
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    if confirm "是否删除脚本自身 (${BASH_SOURCE[0]})？(y/n): "; then
      rm -f "${BASH_SOURCE[0]}"
      ok "脚本已删除"
    fi
  fi
}

# ─────────────────────────────────────────────
# 主入口
# ─────────────────────────────────────────────
main() {
  # curl | bash 时 BASH_SOURCE[0] 为空或为 bash，需跳过删除检查
  echo -e "${BOLD}${CYAN}"
  cat <<'BANNER'
  ╔═══════════════════════════════════════════╗
  ║     SSH 安全加固脚本  v1.0                ║
  ║     Debian / Ubuntu VPS                   ║
  ╚═══════════════════════════════════════════╝
BANNER
  echo -e "${RESET}"

  SSHD_CONF_DIR=""
  F2B_INSTALLED=false

  phase_precheck
  echo ""
  confirm "预检查完成，开始配置公钥？(y/n): " || exit 0

  phase_pubkey
  echo ""
  confirm "公钥配置完成，开始安全加固（禁用密码/配置 fail2ban）？(y/n): " || exit 0

  phase_harden
  phase_finish
}

main "$@"
