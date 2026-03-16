#!/usr/bin/env bash
# add-user.sh — Debian/Ubuntu VPS 新用户创建与 SSH 安全配置脚本（ssh-hardening.sh 续集）
# 支持远程执行：bash <(curl -sSL https://raw.githubusercontent.com/sealeelike/Cool-server/main/add-user.sh)
#
# 功能：
#   1. 创建新用户并设置密码
#   2. 配置 sudo 权限（无/需密码/免密）
#   3. 为新用户写入 SSH 公钥
#   4. 通过 Match User 块仅禁用该用户的 SSH 密码登录（其他用户不受影响）
#   5. 测试公钥登录，测试失败可回滚
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
  local prompt="${1:-继续？}"
  local default="${2:-}"
  local hint
  case "${default,,}" in
    y) hint="[Y/n]" ;;
    n) hint="[y/N]" ;;
    *) hint="[y/n]" ;;
  esac
  local answer
  read -r -p "$(echo -e "  ${YELLOW}${prompt} ${hint}: ${RESET}")" answer
  if [[ -z "$answer" ]]; then
    answer="${default}"
  fi
  [[ "${answer,,}" =~ ^y$ ]]
}

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
# 全局变量（阶段间共享状态）
# ─────────────────────────────────────────────
NEW_USER=""
NEW_USER_HOME=""
SSHD_CONF_DIR=""
PUBKEY_ADDED=false
MATCH_BLOCK_ADDED=false
USER_CREATED=false

# ─────────────────────────────────────────────
# 辅助：检查 sshd_config.d 的配置文件状态
# ─────────────────────────────────────────────
# 要求 sshd_config.d 中最多只存在一个配置文件，且必须是本套件管理的
# 99-managed-ssh.conf。若存在多个文件或未知文件，则停止执行并给出说明。
# 背景：Match User 块必须位于整个 SSH 有效配置的末尾。由于 Debian/Ubuntu
# 的 sshd_config 将 Include 放在文件顶部，include 结束后 sshd_config 本体
# 的剩余内容会紧接在最后一个 include 文件之后解析，若该文件以开放的 Match
# 块结尾，sshd_config 的后续全局指令就会被纳入该 Match 块作用域，造成
# 安全配置失效。因此本脚本始终将 Match User 块追加到 /etc/ssh/sshd_config
# 末尾，而全局设置则集中写入唯一一个托管文件 99-managed-ssh.conf。
_check_sshd_conf_state() {
  local managed="${SSHD_CONF_DIR}/99-managed-ssh.conf"
  local conf_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && conf_files+=("$f")
  done < <(privileged find "$SSHD_CONF_DIR" -maxdepth 1 -name "*.conf" 2>/dev/null | sort)

  local count=${#conf_files[@]}

  if [[ $count -eq 0 ]]; then
    info "sshd_config.d 目录为空，将在需要时自动创建 99-managed-ssh.conf"
    return 0
  fi

  if [[ $count -eq 1 && -f "$managed" ]]; then
    ok "发现托管配置文件: 99-managed-ssh.conf"
    return 0
  fi

  # 存在多个文件，或唯一文件不是托管文件
  echo ""
  fail "sshd_config.d 中存在非预期的配置文件（共 ${count} 个）："
  for f in "${conf_files[@]}"; do
    echo "     - $(basename "$f")"
  done
  echo ""
  die "多个 SSH drop-in 配置文件会使最终配置的作用域和顺序存在歧义，无法安全继续。
  如果以上文件是由旧版 ssh-hardening.sh 生成的（如 10-pubkey.conf、20-security.conf），
  请重新运行最新版 ssh-hardening.sh，它会自动将这些文件合并为 99-managed-ssh.conf。
  如果是由旧版 add-user.sh 生成的（如 30-user-*.conf），请手动删除这些文件，
  Match User 块现在统一追加到 /etc/ssh/sshd_config 末尾，无需独立 conf 文件。
  整理完毕后重新运行本脚本。"
}

# ─────────────────────────────────────────────
# 阶段一：预检查
# ─────────────────────────────────────────────
phase_precheck() {
  print_phase "[阶段 1/4] 预检查"

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
        confirm "仍要继续？" "n" || exit 0
        ;;
    esac
  else
    warn "无法识别系统版本，继续执行"
  fi

  # 3. sshd include 目录
  if grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null \
      && [[ -d /etc/ssh/sshd_config.d ]]; then
    ok "sshd 支持 include 目录 (/etc/ssh/sshd_config.d/)"
    SSHD_CONF_DIR="/etc/ssh/sshd_config.d"
    _check_sshd_conf_state
  else
    warn "sshd_config 中未找到 Include 指令或目录不存在，将直接修改 /etc/ssh/sshd_config"
    SSHD_CONF_DIR=""
  fi

  # 4. 当前 SSH 全局认证配置摘要
  echo ""
  info "当前 SSH 全局认证配置（若 PubkeyAuthentication 未启用，本脚本将自动全局开启）："
  for key in PubkeyAuthentication PasswordAuthentication PermitRootLogin; do
    val=$(privileged sshd -T 2>/dev/null | grep -i "^${key} " | awk '{print $2}' || echo "未知")
    printf "     %-35s %s\n" "${key}:" "${val}"
  done
}

# ─────────────────────────────────────────────
# 阶段二：用户创建
# ─────────────────────────────────────────────
phase_create_user() {
  print_phase "[阶段 2/4] 用户创建"

  # 2.1 用户名
  while true; do
    echo ""
    read -r -p "$(echo -e "  ${YELLOW}请输入新用户名: ${RESET}")" NEW_USER
    if [[ -z "$NEW_USER" ]]; then
      warn "用户名不能为空，请重新输入"
      continue
    fi
    if [[ ! "$NEW_USER" =~ ^[a-z_]([a-z0-9_-]*[a-z0-9_])?$ ]]; then
      warn "用户名只能包含小写字母、数字、连字符和下划线，且必须以字母或下划线开头、以字母/数字/下划线结尾"
      continue
    fi
    break
  done

  # 2.2 用户是否已存在
  if id "$NEW_USER" >/dev/null 2>&1; then
    warn "用户 ${NEW_USER} 已存在"
    NEW_USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
    info "该用户主目录: ${NEW_USER_HOME}"
    if ! confirm "已存在用户 ${NEW_USER}，是否继续为其配置 SSH 公钥？" "n"; then
      exit 0
    fi
    USER_CREATED=false
  else
    # 创建用户
    privileged useradd -m -s /bin/bash "$NEW_USER"
    ok "用户 ${NEW_USER} 已创建"
    NEW_USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
    USER_CREATED=true
  fi

  # 2.3 设置密码（仅对新用户；已存在用户跳过，避免意外重置密码）
  if [[ "$USER_CREATED" == true ]]; then
    echo ""
    info "为用户 ${NEW_USER} 设置登录密码（用于本地登录和 sudo，SSH 登录将只允许公钥）"
    while true; do
      local pass1 pass2
      read -r -s -p "$(echo -e "  ${YELLOW}请输入密码: ${RESET}")" pass1
      echo ""
      read -r -s -p "$(echo -e "  ${YELLOW}请再次输入密码确认: ${RESET}")" pass2
      echo ""
      if [[ -z "$pass1" ]]; then
        warn "密码不能为空，请重新输入"
        continue
      fi
      if [[ "$pass1" != "$pass2" ]]; then
        warn "两次输入的密码不一致，请重新输入"
        continue
      fi
      printf '%s:%s\n' "$NEW_USER" "$pass1" | privileged chpasswd
      ok "用户 ${NEW_USER} 的密码已设置"
      break
    done

    # 2.4 sudo 权限（仅对新用户）
    echo ""
    info "设置 ${NEW_USER} 的 sudo 权限："
    echo "     1) 无 sudo 权限"
    echo "     2) 完整 sudo 权限（执行 sudo 时需要输入密码）"
    echo "     3) 免密 sudo 权限（执行 sudo 时无需输入密码）"
    echo ""
    local sudo_choice
    while true; do
      read -r -p "$(echo -e "  ${YELLOW}请选择 [1/2/3]: ${RESET}")" sudo_choice
      case "$sudo_choice" in
        1)
          if groups "$NEW_USER" 2>/dev/null | grep -qw "sudo"; then
            privileged deluser "$NEW_USER" sudo >/dev/null 2>&1 || true
          fi
          if [[ -f "/etc/sudoers.d/${NEW_USER}" ]]; then
            privileged rm -f "/etc/sudoers.d/${NEW_USER}"
          fi
          ok "用户 ${NEW_USER} 无 sudo 权限"
          break
          ;;
        2)
          privileged usermod -aG sudo "$NEW_USER"
          if [[ -f "/etc/sudoers.d/${NEW_USER}" ]]; then
            privileged rm -f "/etc/sudoers.d/${NEW_USER}"
          fi
          ok "用户 ${NEW_USER} 已加入 sudo 组（需要密码）"
          break
          ;;
        3)
          privileged usermod -aG sudo "$NEW_USER"
          printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$NEW_USER" | privileged tee "/etc/sudoers.d/${NEW_USER}" >/dev/null
          privileged chmod 440 "/etc/sudoers.d/${NEW_USER}"
          ok "用户 ${NEW_USER} 已设置免密 sudo"
          break
          ;;
        *)
          warn "请输入 1、2 或 3"
          ;;
      esac
    done
  else
    info "已存在用户 ${NEW_USER}，跳过密码和 sudo 设置，仅配置 SSH 公钥"
  fi
}

# ─────────────────────────────────────────────
# 阶段三：SSH 公钥配置
# ─────────────────────────────────────────────
phase_pubkey() {
  print_phase "[阶段 3/4] SSH 公钥配置"

  local ssh_dir="${NEW_USER_HOME}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  # 显示已有公钥
  _show_existing_pubkeys "$auth_keys"

  # 读取并验证公钥
  echo ""
  echo -e "  ${YELLOW}请输入 ${NEW_USER} 的 SSH 公钥（ssh-ed25519 或 ssh-rsa 开头，整行粘贴后回车）:${RESET}"
  local pubkey=""
  local tmpkey
  tmpkey=$(mktemp)
  while true; do
    read -r -p "  > " pubkey
    if [[ "$pubkey" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]] ]]; then
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
  if [[ ! -d "$ssh_dir" ]]; then
    privileged mkdir -p "$ssh_dir"
    ok "已创建目录 ${ssh_dir}"
  fi
  privileged chmod 700 "$ssh_dir"
  privileged chown "${NEW_USER}:${NEW_USER}" "$ssh_dir"

  # 写入 authorized_keys（避免重复写入：对 authorized_keys 中所有字段搜索 key material）
  local pubkey_material
  pubkey_material=$(awk '{print $2}' <<< "$pubkey")
  if privileged grep -qF "$pubkey_material" "$auth_keys" 2>/dev/null; then
    warn "公钥已存在于 ${auth_keys}，跳过写入"
  else
    printf '%s\n' "$pubkey" | privileged tee -a "$auth_keys" >/dev/null
    ok "公钥已写入 ${auth_keys}"
    PUBKEY_ADDED=true
  fi
  privileged chmod 600 "$auth_keys"
  privileged chown "${NEW_USER}:${NEW_USER}" "$auth_keys"
  ok "权限已设置: ${ssh_dir} (700), ${auth_keys} (600)"

  # 确保全局 PubkeyAuthentication 已启用
  _ensure_pubkey_auth_enabled

  # 为该用户添加 Match User 块，仅限公钥登录（不影响其他用户）
  _add_user_match_block

  # 重启 SSH
  _restart_ssh
  ok "SSH 服务已重启"

  # 提示测试
  echo ""
  echo -e "${YELLOW}  ─────────────────────────────────────────────${RESET}"
  warn "请在【新终端】测试 ${NEW_USER} 的公钥登录，成功后再继续！"
  echo ""
  echo -e "  Windows PowerShell 示例："
  echo -e "  ${CYAN}ssh -i C:\\Users\\你的用户名\\.ssh\\id_ed25519 ${NEW_USER}@你的服务器IP${RESET}"
  echo ""
  echo -e "  Linux / macOS 示例："
  echo -e "  ${CYAN}ssh -i ~/.ssh/id_ed25519 ${NEW_USER}@你的服务器IP${RESET}"
  echo -e "${YELLOW}  ─────────────────────────────────────────────${RESET}"
  echo ""

  if ! confirm "${NEW_USER} 的公钥登录测试成功了吗？" "n"; then
    warn "公钥登录测试未成功"
    _offer_rollback "$pubkey" "$auth_keys"
    warn "请先确认公钥登录成功后再继续，脚本已退出"
    exit 0
  fi

  ok "用户已确认公钥登录成功，配置已生效"
}

# ─────────────────────────────────────────────
# 辅助：显示已有公钥
# ─────────────────────────────────────────────
_show_existing_pubkeys() {
  local auth_keys="$1"
  echo ""
  info "目标文件 ${auth_keys} 中已有的公钥："
  if privileged test -f "$auth_keys" && privileged test -s "$auth_keys" 2>/dev/null; then
    local i=1
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      local keytype comment
      keytype=$(awk '{print $1}' <<< "$line")
      comment=$(awk '{$1=$2=""; sub(/^[[:space:]]+/,"",$0); print}' <<< "$line")
      printf "     %d) %-30s %s\n" "$i" "$keytype" "${comment:-<无注释>}"
      ((i++))
    done < <(privileged cat "$auth_keys")
    if (( i == 1 )); then
      echo -e "     （文件存在但无有效公钥行）"
    fi
  else
    echo -e "     （暂无已添加的公钥）"
  fi
}

# ─────────────────────────────────────────────
# 辅助：确保全局 PubkeyAuthentication yes
# ─────────────────────────────────────────────
_ensure_pubkey_auth_enabled() {
  local current_val
  current_val=$(privileged sshd -T 2>/dev/null | grep -i "^PubkeyAuthentication " | awk '{print $2}' || echo "")
  if [[ "${current_val,,}" == "yes" ]]; then
    ok "PubkeyAuthentication 已启用（全局）"
    return 0
  fi
  if [[ -n "$SSHD_CONF_DIR" ]]; then
    local conf="${SSHD_CONF_DIR}/99-managed-ssh.conf"
    if [[ -f "$conf" ]]; then
      if ! grep -qE '^\s*PubkeyAuthentication\s+yes' "$conf" 2>/dev/null; then
        printf 'PubkeyAuthentication yes\n' | privileged tee -a "$conf" >/dev/null
        ok "已在 ${conf} 中追加 PubkeyAuthentication yes"
      fi
    else
      printf 'PubkeyAuthentication yes\n' | privileged tee "$conf" >/dev/null
      ok "已创建 ${conf} 并启用 PubkeyAuthentication"
    fi
  else
    _set_sshd_option "PubkeyAuthentication" "yes" /etc/ssh/sshd_config
    ok "已在 /etc/ssh/sshd_config 中启用 PubkeyAuthentication"
  fi
  privileged sshd -t || die "sshd 配置检查失败，请手动排查"
}

# ─────────────────────────────────────────────
# 辅助：为新用户添加 Match User 块（仅禁用该用户的密码登录）
# ─────────────────────────────────────────────
# 重要：Match User 块必须追加到 /etc/ssh/sshd_config 末尾，而不能放在
# sshd_config.d 中的任何 conf 文件里。原因：Debian/Ubuntu 的 sshd_config
# 将 Include 放在文件顶部，所有 include 的 conf 文件在 sshd_config 本体
# 的其余内容之前被处理；若某个 conf 文件以开放的 Match 块结尾，sshd_config
# 后续的全局指令（如 PasswordAuthentication yes）会被纳入该 Match 的作用域，
# 导致安全配置意外失效。将 Match 块追加到 sshd_config 末尾是唯一能保证其
# 位于所有有效配置最后的方法。
_add_user_match_block() {
  local begin_marker="### BEGIN add-user: ${NEW_USER} ###"
  local end_marker="### END add-user: ${NEW_USER} ###"
  # AuthenticationMethods 与 PasswordAuthentication 均可在 Match 块中使用
  local match_content
  match_content="${begin_marker}
# Only allow pubkey authentication for ${NEW_USER} — managed by add-user.sh
Match User ${NEW_USER}
    AuthenticationMethods publickey
    PasswordAuthentication no
${end_marker}"

  local cfg=/etc/ssh/sshd_config
  if privileged grep -qF "$begin_marker" "$cfg" 2>/dev/null; then
    warn "sshd_config 中已存在 ${NEW_USER} 的 Match User 块，跳过写入"
  else
    printf '\n%s\n' "$match_content" | privileged tee -a "$cfg" >/dev/null
    ok "已在 /etc/ssh/sshd_config 末尾追加 Match User ${NEW_USER} 块"
    MATCH_BLOCK_ADDED=true
  fi
  privileged sshd -t || die "sshd 配置检查失败，请手动排查"
}

# ─────────────────────────────────────────────
# 辅助：删除公钥
# ─────────────────────────────────────────────
_remove_pubkey() {
  local pubkey="$1"
  local auth_keys="$2"
  local pubkey_material
  pubkey_material=$(awk '{print $2}' <<< "$pubkey")
  if [[ -z "$pubkey_material" ]]; then
    warn "无法提取公钥内容，跳过删除操作"
    return 1
  fi
  local tmpfile
  tmpfile=$(mktemp)
  if privileged awk -v mat="$pubkey_material" 'NF < 2 || $2 != mat' "$auth_keys" > "$tmpfile"; then
    privileged mv "$tmpfile" "$auth_keys"
    privileged chmod 600 "$auth_keys"
    privileged chown "${NEW_USER}:${NEW_USER}" "$auth_keys"
    ok "已从 ${auth_keys} 中删除公钥"
  else
    rm -f "$tmpfile"
    warn "删除公钥时出错，${auth_keys} 未修改"
    return 1
  fi
}

# ─────────────────────────────────────────────
# 辅助：删除 Match User 块
# ─────────────────────────────────────────────
_remove_match_block() {
  local cfg=/etc/ssh/sshd_config
  local begin_marker="### BEGIN add-user: ${NEW_USER} ###"
  local end_marker="### END add-user: ${NEW_USER} ###"
  local tmpfile
  tmpfile=$(mktemp)
  privileged awk \
    -v begin="$begin_marker" \
    -v end="$end_marker" \
    '$0 == begin { skip=1; next } $0 == end { skip=0; next } !skip { print }' \
    "$cfg" > "$tmpfile"
  privileged mv "$tmpfile" "$cfg"
  ok "已从 /etc/ssh/sshd_config 中删除 Match User ${NEW_USER} 块"
}

# ─────────────────────────────────────────────
# 辅助：测试失败后的回滚选项
# ─────────────────────────────────────────────
_offer_rollback() {
  local pubkey="$1"
  local auth_keys="$2"
  local need_restart=false

  echo ""
  info "回滚选项（可选择撤销刚才的操作）："

  if [[ "$PUBKEY_ADDED" == true ]]; then
    if confirm "是否删除刚刚为 ${NEW_USER} 添加的公钥？" "n"; then
      _remove_pubkey "$pubkey" "$auth_keys"
      PUBKEY_ADDED=false
    fi
  fi

  if [[ "$MATCH_BLOCK_ADDED" == true ]]; then
    if confirm "是否撤销对 ${NEW_USER} 的 SSH 仅公钥限制配置？" "n"; then
      _remove_match_block
      MATCH_BLOCK_ADDED=false
      need_restart=true
    fi
  fi

  if [[ "$USER_CREATED" == true ]]; then
    if confirm "是否删除刚刚创建的用户 ${NEW_USER}（包括其主目录）？" "n"; then
      privileged deluser --remove-home "$NEW_USER" >/dev/null 2>&1 \
        || privileged userdel -r "$NEW_USER" >/dev/null 2>&1 \
        || warn "删除用户时出现错误，请手动检查"
      ok "用户 ${NEW_USER} 已删除"
      USER_CREATED=false
    fi
  fi

  if [[ "$need_restart" == true ]]; then
    _restart_ssh 2>/dev/null || warn "SSH 服务重启失败，请手动执行: systemctl restart ssh"
  fi
}

# ─────────────────────────────────────────────
# 辅助：重启 SSH 服务
# ─────────────────────────────────────────────
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
  local escaped_key escaped_value
  escaped_key=$(printf '%s' "$key" | sed 's/[][\.|$(){}?+*^]/\\&/g')
  escaped_value=$(printf '%s' "$value" | sed 's/[\\|&]/\\&/g')
  if privileged grep -qiE "^\s*#?\s*${escaped_key}(\s|$)" "$file" 2>/dev/null; then
    privileged sed -i -E "s|^(\s*#?\s*)${escaped_key}(\s.*)?$|${key} ${escaped_value}|I" "$file"
  else
    printf '%s %s\n' "$key" "$value" | privileged tee -a "$file" >/dev/null
  fi
}

# ─────────────────────────────────────────────
# 阶段四：收尾摘要
# ─────────────────────────────────────────────
phase_finish() {
  echo ""
  echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${RESET}"
  echo -e "${GREEN}${BOLD}  🎉 用户创建与 SSH 配置完成！${RESET}"
  echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${RESET}"
  echo ""
  echo -e "  ✔ 用户名: ${NEW_USER}"
  echo -e "  ✔ 主目录: ${NEW_USER_HOME}"

  # 显示 sudo 状态
  local sudo_status="无"
  if [[ -f "/etc/sudoers.d/${NEW_USER}" ]] \
      && privileged grep -q "NOPASSWD" "/etc/sudoers.d/${NEW_USER}" 2>/dev/null; then
    sudo_status="免密 sudo"
  elif groups "$NEW_USER" 2>/dev/null | grep -qw "sudo"; then
    sudo_status="sudo（需要密码）"
  fi
  echo -e "  ✔ sudo 权限: ${sudo_status}"
  echo -e "  ✔ SSH 登录: 仅公钥（${NEW_USER} 的密码 SSH 登录已禁用）"
  echo -e "  ✔ 已有用户 SSH 配置不受影响"
  echo ""
  info "通过 Match User 块对 ${NEW_USER} 单独限制密码登录，其他用户不受影响"
  info "全局设置：PubkeyAuthentication yes 已确保启用；其他全局 SSH 配置项未被修改"
  echo ""

  # 询问是否删除脚本自身（不适用于通过 bash <(curl ...) 执行的情况）
  if [[ -f "${BASH_SOURCE[0]:-}" && ! "${BASH_SOURCE[0]:-}" =~ ^/dev/ ]]; then
    if confirm "是否删除脚本自身 (${BASH_SOURCE[0]})？" "n"; then
      rm -f "${BASH_SOURCE[0]}"
      ok "脚本已删除"
    fi
  fi
}

# ─────────────────────────────────────────────
# 主入口
# ─────────────────────────────────────────────
main() {
  echo -e "${BOLD}${CYAN}"
  cat <<'BANNER'
  ╔═══════════════════════════════════════════╗
  ║     新用户创建脚本  v1.0                  ║
  ║     Debian / Ubuntu VPS                   ║
  ╚═══════════════════════════════════════════╝
BANNER
  echo -e "${RESET}"

  echo -e "${YELLOW}${BOLD}  ⚠  重要说明 ⚠${RESET}"
  echo -e "${YELLOW}  ──────────────────────────────────────────────────────${RESET}"
  echo -e "${YELLOW}  本脚本将创建新用户并为其配置 SSH 公钥登录。${RESET}"
  echo -e "${YELLOW}  新用户将被限制为仅允许公钥方式 SSH 登录（通过 Match User 块）。${RESET}"
  echo -e "${YELLOW}  若 PubkeyAuthentication 尚未全局启用，本脚本将自动开启，${RESET}"
  echo -e "${YELLOW}  其他全局 SSH 配置不会被修改，已有用户的登录方式完全不受影响。${RESET}"
  echo -e "${RED}  建议您在执行期间保持当前 SSH 连接处于打开状态。${RESET}"
  echo -e "${YELLOW}  ──────────────────────────────────────────────────────${RESET}"
  echo ""
  echo -e "  ${BOLD}请输入 yes 以确认您已了解上述说明。${RESET}"
  local ack
  read -r -p "$(echo -e "  ${BOLD}输入 yes 继续: ${RESET}")" ack
  if [[ "${ack}" != "yes" ]]; then
    echo -e "  ${RED}未确认，脚本已退出。${RESET}"
    exit 1
  fi
  echo ""

  SSHD_CONF_DIR=""

  phase_precheck
  echo ""
  confirm "预检查完成，开始创建用户？" "y" || exit 0

  phase_create_user
  echo ""
  confirm "用户创建完成，开始配置 SSH 公钥？" "y" || exit 0

  phase_pubkey
  phase_finish
}

main "$@"
