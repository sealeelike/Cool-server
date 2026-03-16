#!/usr/bin/env bash
# migrate-legacy-ssh-conf.sh — one-time migration patch for legacy ssh-hardening.sh installs
#
# Use this only on hosts that still have the old two-file layout:
#   /etc/ssh/sshd_config.d/10-pubkey.conf
#   /etc/ssh/sshd_config.d/20-security.conf
#
# This script merges that legacy layout into:
#   /etc/ssh/sshd_config.d/99-managed-ssh.conf
#
# If the host was set up with the newer scripts already, do not run this file.
# New installs should use ssh-hardening.sh directly and will not need this migration.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✅${RESET} $*"; }
warn() { echo -e "  ${YELLOW}⚠️ ${RESET} $*"; }
info() { echo -e "  ${CYAN}ℹ️ ${RESET} $*"; }
fail() { echo -e "  ${RED}❌${RESET} $*" >&2; }
die()  { fail "$*"; exit 1; }

confirm() {
  local prompt="$1"
  local answer
  read -r -p "$(echo -e "  ${YELLOW}${prompt} [y/N]: ${RESET}")" answer
  [[ "${answer,,}" == "y" ]]
}

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
fi

privileged() {
  $SUDO "$@"
}

SSHD_CONF_DIR="/etc/ssh/sshd_config.d"
OLD_PUBKEY_CONF="${SSHD_CONF_DIR}/10-pubkey.conf"
OLD_SECURITY_CONF="${SSHD_CONF_DIR}/20-security.conf"
NEW_MANAGED_CONF="${SSHD_CONF_DIR}/99-managed-ssh.conf"
BACKUP_DIR=""

precheck() {
  info "Checking current SSH drop-in layout"

  [[ -d "${SSHD_CONF_DIR}" ]] || die "Missing directory: ${SSHD_CONF_DIR}"
  [[ -f /etc/ssh/sshd_config ]] || die "Missing file: /etc/ssh/sshd_config"

  if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    die "This host does not include ${SSHD_CONF_DIR}/*.conf from sshd_config"
  fi

  local conf_files=()
  while IFS= read -r f; do
    [[ -n "${f}" ]] && conf_files+=("${f}")
  done < <(find "${SSHD_CONF_DIR}" -maxdepth 1 -type f -name '*.conf' | sort)

  if (( ${#conf_files[@]} != 2 )); then
    fail "Expected exactly 2 legacy drop-ins, found ${#conf_files[@]}"
    for f in "${conf_files[@]}"; do
      echo "     - $(basename "${f}")"
    done
    die "Refusing to migrate automatically because the layout is not the known legacy two-file state"
  fi

  [[ -f "${OLD_PUBKEY_CONF}" ]] || die "Missing legacy file: ${OLD_PUBKEY_CONF}"
  [[ -f "${OLD_SECURITY_CONF}" ]] || die "Missing legacy file: ${OLD_SECURITY_CONF}"
  [[ ! -e "${NEW_MANAGED_CONF}" ]] || die "Target file already exists: ${NEW_MANAGED_CONF}"

  ok "Detected the known legacy layout"
}

show_plan() {
  echo ""
  info "Planned migration:"
  echo "     - backup 10-pubkey.conf and 20-security.conf"
  echo "     - create 99-managed-ssh.conf"
  echo "     - validate with sshd -t"
  echo "     - remove the two legacy files only after validation succeeds"
  echo ""
}

build_managed_conf() {
  local tmpfile="$1"

  cat > "${tmpfile}" <<'EOF'
# Managed by migrate-legacy-ssh-conf.sh / ssh-hardening.sh
# Consolidated from legacy 10-pubkey.conf and 20-security.conf
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
}

migrate() {
  local tmpfile
  tmpfile=$(mktemp)
  BACKUP_DIR=$(mktemp -d /tmp/ssh-legacy-backup.XXXXXX)

  privileged cp -a "${OLD_PUBKEY_CONF}" "${BACKUP_DIR}/"
  privileged cp -a "${OLD_SECURITY_CONF}" "${BACKUP_DIR}/"
  ok "Backed up legacy files to ${BACKUP_DIR}"

  build_managed_conf "${tmpfile}"
  privileged install -m 644 "${tmpfile}" "${NEW_MANAGED_CONF}"
  rm -f "${tmpfile}"
  ok "Created ${NEW_MANAGED_CONF}"

  if privileged sshd -t; then
    ok "sshd -t passed"
  else
    privileged rm -f "${NEW_MANAGED_CONF}"
    die "sshd -t failed after creating ${NEW_MANAGED_CONF}; migration aborted and new file removed"
  fi

  privileged rm -f "${OLD_PUBKEY_CONF}" "${OLD_SECURITY_CONF}"
  ok "Removed legacy files"
}

finish() {
  echo ""
  ok "Migration completed"
  echo "     New file: ${NEW_MANAGED_CONF}"
  echo "     Backup:   ${BACKUP_DIR}"
  echo ""
  info "No Match block was added. This only normalizes the old hardening layout for the new add-user flow."
}

main() {
  echo -e "${BOLD}${CYAN}"
  cat <<'BANNER'
  ╔═══════════════════════════════════════════╗
  ║   Legacy SSH Conf Migration v1.0         ║
  ║   10-pubkey + 20-security -> 99-managed  ║
  ╚═══════════════════════════════════════════╝
BANNER
  echo -e "${RESET}"

  precheck
  show_plan
  confirm "Proceed with the migration?" || die "Migration cancelled"
  migrate
  finish
}

main "$@"
