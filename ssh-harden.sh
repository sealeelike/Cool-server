#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  SSH 安全加固交互式脚本
#  将 ssh-public-key.md 中的零散命令整合为三阶段自动化流程：
#    阶段一：预检查
#    阶段二：用户远程检查（启用公钥 → 导入密钥 → 远程验证）
#    阶段三：修改防火墙（禁用密码 → fail2ban）
# ============================================================

# ---------- 颜色 / 图标 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
fail() { echo -e "${RED}❌ $*${NC}"; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
step() { echo -e "\n${CYAN}▶ $*${NC}"; }

# ---------- 工具函数 ----------
require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "请使用 root 或 sudo 运行此脚本"
    exit 1
  fi
}

pause_continue() {
  read -r -p "按 Enter 继续..."
}

confirm_yes_no() {
  local prompt="$1"
  local answer
  while true; do
    read -r -p "$prompt [y/n]: " answer
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     echo "请输入 y 或 n" ;;
    esac
  done
}

# 获取当前用户的主目录
current_user_home() {
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "/root"
  else
    echo "$HOME"
  fi
}

# ============================================================
#  阶段一：预检查
# ============================================================
phase_precheck() {
  echo ""
  echo "========================================"
  echo "  阶段一：预检查"
  echo "========================================"

  local errors=0

  # 1) 检测操作系统
  step "检测操作系统..."
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    ok "操作系统: ${PRETTY_NAME:-$ID}"
  else
    warn "无法读取 /etc/os-release，继续执行"
  fi

  # 2) 检测 sshd 是否安装
  step "检测 sshd..."
  if command -v sshd >/dev/null 2>&1; then
    ok "sshd 已安装: $(sshd -V 2>&1 | head -1 || echo '版本未知')"
  else
    fail "未检测到 sshd，请先安装 openssh-server"
    ((errors++))
  fi

  # 3) 检测 sshd_config 是否支持 Include
  step "检测 sshd_config Include 支持..."
  if grep -q '^Include' /etc/ssh/sshd_config 2>/dev/null; then
    ok "sshd_config 已启用 Include 目录"
    grep '^Include' /etc/ssh/sshd_config
  else
    warn "sshd_config 未找到 Include 指令"
    info "脚本将直接修改 sshd_config.d 目录（如目录存在）"
  fi

  # 4) 检测 sshd_config.d 目录
  step "检测 /etc/ssh/sshd_config.d/ 目录..."
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    ok "/etc/ssh/sshd_config.d/ 目录存在"
  else
    warn "/etc/ssh/sshd_config.d/ 目录不存在，将自动创建"
  fi

  # 5) 检测当前 SSH 认证状态
  step "检测当前 SSH 认证配置..."
  local pubkey_status password_status
  pubkey_status=$(sshd -T 2>/dev/null | grep -i '^pubkeyauthentication' | awk '{print $2}') || true
  password_status=$(sshd -T 2>/dev/null | grep -i '^passwordauthentication' | awk '{print $2}') || true
  info "PubkeyAuthentication:    ${pubkey_status:-未知}"
  info "PasswordAuthentication:  ${password_status:-未知}"

  # 6) 检测当前用户
  step "当前用户信息..."
  local user_home
  user_home="$(current_user_home)"
  ok "用户: $(whoami)  主目录: ${user_home}"

  # 7) 检测已有的 authorized_keys
  step "检测已有 authorized_keys..."
  if [[ -f "${user_home}/.ssh/authorized_keys" ]]; then
    local key_count
    key_count=$(grep -c '^ssh-' "${user_home}/.ssh/authorized_keys" 2>/dev/null || echo 0)
    ok "已有 ${key_count} 个公钥"
  else
    info "尚未配置 authorized_keys"
  fi

  echo ""
  if [[ "$errors" -gt 0 ]]; then
    fail "预检查发现 ${errors} 个致命问题，请先修复后再运行"
    exit 1
  fi
  ok "预检查完成，未发现致命问题"
  pause_continue
}

# ============================================================
#  阶段二：用户远程检查
#   2-1  启用公钥认证
#   2-2  导入用户公钥
#   2-3  提示远程验证
# ============================================================
phase_user_remote() {
  echo ""
  echo "========================================"
  echo "  阶段二：用户远程检查"
  echo "========================================"

  # ---- 2-1 启用公钥认证 ----
  step "[2-1] 启用公钥认证..."
  mkdir -p /etc/ssh/sshd_config.d

  local pubkey_conf="/etc/ssh/sshd_config.d/10-pubkey.conf"
  if [[ -f "$pubkey_conf" ]] && grep -q 'PubkeyAuthentication yes' "$pubkey_conf"; then
    ok "10-pubkey.conf 已存在且已启用公钥认证，跳过"
  else
    cat > "$pubkey_conf" <<'CONF'
PubkeyAuthentication yes
CONF
    ok "已写入 ${pubkey_conf}"
  fi

  # 检查配置
  step "检查 sshd 配置语法..."
  if sshd -t 2>&1; then
    ok "sshd 配置语法正确"
  else
    fail "sshd 配置存在语法错误，请手动检查"
    exit 1
  fi

  # 重启 SSH
  step "重启 SSH 服务..."
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  ok "SSH 服务已重启"

  # ---- 2-2 导入用户公钥 ----
  step "[2-2] 导入用户公钥..."
  local user_home
  user_home="$(current_user_home)"
  local ssh_dir="${user_home}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  echo ""
  info "请粘贴你的 SSH 公钥（ssh-ed25519 或 ssh-rsa 开头的完整一行）"
  info "如果有多个公钥，请每行粘贴一个"
  info "输入完成后，输入空行（直接按 Enter）结束"
  echo ""

  local key_count=0
  while true; do
    local pubkey
    read -r -p "公钥> " pubkey
    if [[ -z "$pubkey" ]]; then
      break
    fi
    # 基本格式校验
    if [[ "$pubkey" =~ ^ssh-(ed25519|rsa|ecdsa|dss)[[:space:]] ]] || [[ "$pubkey" =~ ^ecdsa-sha2-nistp[0-9]+[[:space:]] ]]; then
      echo "$pubkey" >> "$auth_keys"
      ((key_count++))
      ok "已添加公钥 #${key_count}"
    else
      warn "格式不符合预期，跳过此行（应以 ssh-ed25519/ssh-rsa 等开头）"
    fi
  done

  if [[ "$key_count" -eq 0 ]]; then
    warn "未添加任何公钥"
    if ! confirm_yes_no "是否继续？（如果之前已有公钥可选 y）"; then
      echo "已中止。"
      exit 0
    fi
  else
    chmod 600 "$auth_keys"
    ok "共添加 ${key_count} 个公钥到 ${auth_keys}"
  fi

  # ---- 2-3 远程验证 ----
  step "[2-3] 请在新的远程终端测试公钥登录"
  echo ""
  local server_ip
  server_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  local current_user
  current_user=$(whoami)

  echo "========================================"
  echo "  请打开一个 **新的** 终端窗口测试登录"
  echo "========================================"
  echo ""
  info "Windows Terminal / PowerShell 示例命令："
  echo ""
  echo "  # 使用默认密钥登录"
  echo "  ssh ${current_user}@${server_ip:-你的服务器IP}"
  echo ""
  echo "  # 使用指定私钥登录（ed25519）"
  echo "  ssh -i C:\\Users\\你的用户名\\.ssh\\id_ed25519 ${current_user}@${server_ip:-你的服务器IP}"
  echo ""
  echo "  # 使用指定私钥登录（rsa）"
  echo "  ssh -i C:\\Users\\你的用户名\\.ssh\\id_rsa ${current_user}@${server_ip:-你的服务器IP}"
  echo ""
  warn "⚠️  确认公钥登录成功后再继续！否则禁用密码后你可能无法登录！"
  echo ""

  if ! confirm_yes_no "公钥登录测试是否成功？"; then
    fail "请先解决公钥登录问题后再运行此脚本"
    info "常见问题排查："
    echo "  1. 检查公钥是否正确粘贴"
    echo "  2. 检查本地私钥文件权限（chmod 600）"
    echo "  3. 检查服务器 ~/.ssh 目录权限（700）和 authorized_keys 权限（600）"
    exit 1
  fi

  ok "用户确认公钥登录成功"
  pause_continue
}

# ============================================================
#  阶段三：修改防火墙
#   3-1  禁用密码登录
#   3-2  安装配置 fail2ban
#   3-3  验证
# ============================================================
phase_firewall() {
  echo ""
  echo "========================================"
  echo "  阶段三：修改防火墙"
  echo "========================================"

  # ---- 3-1 禁用密码登录 ----
  step "[3-1] 禁用密码登录（仅允许公钥）..."

  local security_conf="/etc/ssh/sshd_config.d/20-security.conf"
  if [[ -f "$security_conf" ]]; then
    warn "${security_conf} 已存在"
    if ! confirm_yes_no "是否覆盖？"; then
      info "跳过写入 ${security_conf}"
    else
      write_security_conf "$security_conf"
    fi
  else
    write_security_conf "$security_conf"
  fi

  # 检查配置
  step "检查 sshd 配置语法..."
  if sshd -t 2>&1; then
    ok "sshd 配置语法正确"
  else
    fail "sshd 配置存在语法错误，请手动检查"
    exit 1
  fi

  # 重启 SSH
  step "重启 SSH 服务..."
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  ok "SSH 服务已重启（密码登录已禁用）"

  # ---- 3-2 安装配置 fail2ban ----
  step "[3-2] 安装 fail2ban..."
  if command -v fail2ban-client >/dev/null 2>&1; then
    ok "fail2ban 已安装"
  else
    info "正在安装 fail2ban..."
    apt-get update -qq
    apt-get install -y -qq fail2ban
    ok "fail2ban 安装完成"
  fi

  systemctl enable fail2ban 2>/dev/null || true
  ok "fail2ban 已设为开机自启"

  step "写入 jail 配置（sshd + recidive）..."
  local jail_conf="/etc/fail2ban/jail.local"
  if [[ -f "$jail_conf" ]]; then
    warn "${jail_conf} 已存在"
    if ! confirm_yes_no "是否覆盖？"; then
      info "跳过写入 ${jail_conf}"
    else
      write_jail_conf "$jail_conf"
    fi
  else
    write_jail_conf "$jail_conf"
  fi

  # ---- 3-3 验证 ----
  step "[3-3] 验证 fail2ban..."

  info "测试 fail2ban 配置..."
  if fail2ban-client -t 2>&1; then
    ok "fail2ban 配置语法正确"
  else
    fail "fail2ban 配置有误，请手动检查 ${jail_conf}"
    exit 1
  fi

  step "重启 fail2ban..."
  systemctl restart fail2ban
  ok "fail2ban 已重启"

  step "查看 fail2ban 状态..."
  fail2ban-client status 2>&1 || true

  step "查看 sshd jail 状态..."
  fail2ban-client status sshd 2>&1 || true

  echo ""
  ok "阶段三完成：防火墙配置已就绪"
  pause_continue
}

# ---------- 配置写入辅助函数 ----------
write_security_conf() {
  local target="$1"
  cat > "$target" <<'CONF'
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
CONF
  ok "已写入 ${target}"
}

write_jail_conf() {
  local target="$1"
  cat > "$target" <<'CONF'
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
CONF
  ok "已写入 ${target}"
}

# ============================================================
#  最终总结
# ============================================================
summary() {
  echo ""
  echo "========================================"
  echo "  🎉 SSH 安全加固完成"
  echo "========================================"
  echo ""
  ok "✔ 只允许公钥登录"
  ok "✔ root 仅允许公钥"
  ok "✔ 密码认证已禁用"
  ok "✔ SSH 爆破自动封禁（fail2ban）"
  ok "✔ 累犯封禁 7 天（recidive）"
  echo ""
  info "可选后续操作："
  echo "  • 限制 journald 日志大小：编辑 /etc/systemd/journald.conf"
  echo "    设置 SystemMaxUse=200M 和 SystemKeepFree=500M"
  echo "  • 更改 SSH 端口：在 /etc/ssh/sshd_config.d/ 中添加 Port 配置"
  echo "  • 添加 nftables 白名单：仅允许指定 IP 访问 22 端口"
  echo ""
}

# ============================================================
#  主入口
# ============================================================
main() {
  echo ""
  echo "========================================"
  echo "  SSH 安全加固交互式脚本"
  echo "  基于 Debian 11/12 推荐配置"
  echo "========================================"
  echo ""
  info "本脚本将分三个阶段执行："
  echo "  1) 预检查：系统环境与 SSH 状态"
  echo "  2) 用户远程检查：启用公钥 → 导入密钥 → 验证登录"
  echo "  3) 修改防火墙：禁用密码 → 安装 fail2ban"
  echo ""

  if ! confirm_yes_no "是否开始执行？"; then
    echo "已取消。"
    exit 0
  fi

  require_root

  phase_precheck
  phase_user_remote
  phase_firewall
  summary
}

main "$@"
