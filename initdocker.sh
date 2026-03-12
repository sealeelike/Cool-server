#!/usr/bin/env bash

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

DOCKER_USER_DEFAULT="dockeruser"
DOCKER_USER=""
DOCKER_HOME=""
OS_ID=""
OS_VERSION_CODENAME=""
SUDO=""
TEMP_PROXY_URL=""
DOCKER_PROXY_URL=""
DOCKER_MIRROR_URL=""
CHECK_PATH=""

ok() { echo -e "  ${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
info() { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
fail() { echo -e "  ${RED}[ERROR]${RESET} $*" >&2; exit 1; }

print_phase() {
  echo ""
  echo -e "${BOLD}${CYAN}$1${RESET}"
  echo -e "${CYAN}$(printf '%.0s-' {1..52})${RESET}"
}

privileged() {
  if [[ -n "$SUDO" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

confirm() {
  local prompt="${1:-Continue?}" default="${2:-y}" hint answer
  case "${default,,}" in
    y) hint="[Y/n]" ;;
    n) hint="[y/N]" ;;
    *) hint="[y/n]" ;;
  esac
  read -r -p "$(echo -e "  ${YELLOW}${prompt} ${hint}: ${RESET}")" answer
  [[ "${answer:-$default}" =~ ^[Yy]$ ]]
}

prompt_value() {
  local __var_name="$1" prompt="$2" default="${3:-}" required="${4:-false}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$(echo -e "  ${CYAN}${prompt} [default: ${default}]: ${RESET}")" answer
    answer="${answer:-$default}"
  else
    read -r -p "$(echo -e "  ${CYAN}${prompt}: ${RESET}")" answer
  fi
  [[ "$required" != "true" || -n "$answer" ]] || fail "${prompt} cannot be empty"
  printf -v "$__var_name" '%s' "$answer"
}

check_privilege() {
  if [[ "$(id -u)" -eq 0 ]]; then
    ok "root detected"
  elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    sudo -n true >/dev/null 2>&1 && ok "sudo detected" || info "sudo password may be required during installation"
  else
    fail "please run as root or with sudo"
  fi
}

detect_os() {
  [[ -r /etc/os-release ]] || fail "/etc/os-release not found"
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$OS_VERSION_CODENAME" ]] || OS_VERSION_CODENAME="$(lsb_release -cs 2>/dev/null || true)"

  case "$OS_ID" in
    ubuntu|debian) ok "system: ${PRETTY_NAME:-$OS_ID}" ;;
    *)
      warn "current distro is ${PRETTY_NAME:-unknown}; this script is intended for Debian/Ubuntu"
      confirm "Continue anyway?" "n" || exit 0
      ;;
  esac

  [[ -n "$OS_VERSION_CODENAME" ]] || fail "cannot detect distro codename"
}

prompt_docker_user() {
  prompt_value DOCKER_USER "Docker username" "$DOCKER_USER_DEFAULT"
  [[ "$DOCKER_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "invalid username: ${DOCKER_USER}"
  DOCKER_HOME="/home/${DOCKER_USER}"
  ok "Docker user will be: ${DOCKER_USER}"
}

prompt_check_path() {
  prompt_value CHECK_PATH "Extra path to inspect for leftover files [optional]"
  [[ -n "$CHECK_PATH" ]] && info "will inspect: ${CHECK_PATH}" || info "no extra path inspection requested"
}

prompt_temp_proxy() {
  confirm "Set a temporary proxy for this installation only?" "n" || {
    info "skip temporary proxy"
    return
  }
  prompt_value TEMP_PROXY_URL "Proxy URL (example: http://127.0.0.1:7890)" "" true
  export http_proxy="$TEMP_PROXY_URL" https_proxy="$TEMP_PROXY_URL" HTTP_PROXY="$TEMP_PROXY_URL" HTTPS_PROXY="$TEMP_PROXY_URL"
  ok "temporary proxy enabled for current script"
}

prompt_docker_network_options() {
  echo ""
  if confirm "Configure a persistent proxy for Docker pulls later?" "n"; then
    prompt_value DOCKER_PROXY_URL "Docker proxy URL" "" true
    ok "persistent Docker proxy will be configured"
  else
    info "skip persistent Docker proxy"
  fi

  if confirm "Configure a Docker registry mirror?" "n"; then
    prompt_value DOCKER_MIRROR_URL "Mirror URL (example: https://mirror.example.com)" "" true
    ok "Docker registry mirror will be configured"
  else
    info "skip registry mirror"
  fi
}

inspect_item() {
  local kind="$1" path="$2"
  local label="file"
  [[ "$kind" == "-d" ]] && label="directory"
  [[ "$kind" == "-e" ]] && label="path"
  if privileged test "$kind" "$path"; then
    warn "${label} exists: $path"
    return 0
  fi
  info "${label} not found: $path"
  return 1
}

inspect_current_environment() {
  local found_any="false"

  info "checking current Docker-related environment"

  if command -v docker >/dev/null 2>&1; then
    ok "docker command already exists: $(docker --version 2>/dev/null || echo installed)"
    found_any="true"
  else
    info "docker command not found"
  fi

  if privileged systemctl list-unit-files docker.service >/dev/null 2>&1; then
    privileged systemctl is-active --quiet docker && ok "docker service is already active" || warn "docker service exists but is not active"
    found_any="true"
  else
    info "docker service not found"
  fi

  if getent group docker >/dev/null 2>&1; then
    ok "docker group already exists"
    found_any="true"
  else
    info "docker group not found"
  fi

  if id "$DOCKER_USER" >/dev/null 2>&1; then
    ok "user ${DOCKER_USER} already exists"
    found_any="true"
  else
    info "user ${DOCKER_USER} does not exist yet"
  fi

  for dir in /etc/docker /etc/systemd/system/docker.service.d; do
    inspect_item -d "$dir" && found_any="true"
  done

  for file in \
    /etc/docker/daemon.json \
    /etc/systemd/system/docker.service.d/http-proxy.conf \
    /etc/apt/sources.list.d/docker.list \
    /etc/apt/apt.conf.d/90codex-proxy; do
    inspect_item -f "$file" && found_any="true"
  done

  if [[ -n "$CHECK_PATH" ]]; then
    inspect_item -e "$CHECK_PATH" && found_any="true"
  fi

  if [[ "$found_any" == "true" ]]; then
    warn "existing Docker-related state was detected; re-running may overwrite some config files"
    confirm "Continue with installation?" "y" || exit 0
  else
    ok "no existing Docker installation detected"
  fi
}

write_temp_apt_proxy() {
  [[ -n "$TEMP_PROXY_URL" ]] || return 0
  info "configuring temporary apt proxy"
  privileged tee /etc/apt/apt.conf.d/90codex-proxy >/dev/null <<EOF
Acquire::http::Proxy "${TEMP_PROXY_URL}";
Acquire::https::Proxy "${TEMP_PROXY_URL}";
EOF
}

cleanup_temp_apt_proxy() {
  [[ -n "$TEMP_PROXY_URL" ]] || return 0
  info "removing temporary apt proxy"
  privileged rm -f /etc/apt/apt.conf.d/90codex-proxy
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  info "updating apt package index"
  privileged apt-get update -y
  info "installing required packages"
  privileged apt-get install -y ca-certificates curl gnupg lsb-release uidmap dbus-user-session apt-transport-https software-properties-common
}

setup_docker_repo() {
  local arch keyring="/etc/apt/keyrings/docker.gpg"
  arch="$(dpkg --print-architecture)"
  info "configuring docker apt repository"
  privileged install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | privileged gpg --dearmor -o "$keyring"
  privileged chmod a+r "$keyring"
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$keyring" "$OS_ID" "$OS_VERSION_CODENAME" | privileged tee /etc/apt/sources.list.d/docker.list >/dev/null
  privileged apt-get update -y
}

install_docker() {
  info "installing docker engine"
  privileged apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  privileged systemctl enable --now docker
}

ensure_user_and_group() {
  getent group docker >/dev/null 2>&1 && ok "docker group already exists" || {
    info "creating docker group"
    privileged groupadd docker
  }

  if id "$DOCKER_USER" >/dev/null 2>&1; then
    ok "user ${DOCKER_USER} already exists"
  else
    info "creating user ${DOCKER_USER}"
    privileged useradd -m -d "$DOCKER_HOME" -s /bin/bash "$DOCKER_USER"
  fi

  info "adding ${DOCKER_USER} to docker group"
  privileged usermod -aG docker "$DOCKER_USER"
  privileged install -d -m 0755 -o "$DOCKER_USER" -g "$DOCKER_USER" "${DOCKER_HOME}/docker"
}

configure_docker_network() {
  [[ -n "$DOCKER_PROXY_URL" || -n "$DOCKER_MIRROR_URL" ]] || return 0

  if [[ -n "$DOCKER_PROXY_URL" ]]; then
    confirm_overwrite "/etc/systemd/system/docker.service.d/http-proxy.conf" "Docker proxy config" || {
      info "skip Docker proxy configuration"
      DOCKER_PROXY_URL=""
    }
  fi

  if [[ -n "$DOCKER_MIRROR_URL" ]]; then
    confirm_overwrite "/etc/docker/daemon.json" "Docker daemon config" || {
      info "skip Docker registry mirror configuration"
      DOCKER_MIRROR_URL=""
    }
  fi

  [[ -n "$DOCKER_PROXY_URL" || -n "$DOCKER_MIRROR_URL" ]] || return 0

  if [[ -n "$DOCKER_PROXY_URL" ]]; then
    info "writing Docker proxy configuration"
    privileged install -d -m 0755 /etc/systemd/system/docker.service.d
    privileged tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null <<EOF
[Service]
Environment="HTTP_PROXY=${DOCKER_PROXY_URL}"
Environment="HTTPS_PROXY=${DOCKER_PROXY_URL}"
Environment="http_proxy=${DOCKER_PROXY_URL}"
Environment="https_proxy=${DOCKER_PROXY_URL}"
EOF
  fi

  if [[ -n "$DOCKER_MIRROR_URL" ]]; then
    info "writing Docker daemon mirror configuration"
    privileged install -d -m 0755 /etc/docker
    privileged tee /etc/docker/daemon.json >/dev/null <<EOF
{
  "registry-mirrors": ["${DOCKER_MIRROR_URL}"]
}
EOF
  fi

  privileged systemctl daemon-reload
  privileged systemctl restart docker
}

verify_installation() {
  privileged systemctl is-active --quiet docker || fail "docker service is not active"
  privileged docker --version
  privileged docker compose version
  privileged su - "$DOCKER_USER" -c "docker ps" >/dev/null
  ok "docker can be used without sudo for user ${DOCKER_USER}"
}

print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}====================================================${RESET}"
  echo -e "${GREEN}${BOLD} Docker environment is ready${RESET}"
  echo -e "${GREEN}${BOLD}====================================================${RESET}"
  echo ""
  echo -e "  Docker user : ${BOLD}${DOCKER_USER}${RESET}"
  echo -e "  Home        : ${BOLD}${DOCKER_HOME}${RESET}"
  echo -e "  Workspace   : ${BOLD}${DOCKER_HOME}/docker${RESET}"
  [[ -z "$TEMP_PROXY_URL" ]] || echo -e "  Temp proxy  : ${BOLD}${TEMP_PROXY_URL}${RESET}"
  [[ -z "$DOCKER_PROXY_URL" ]] || echo -e "  Docker proxy: ${BOLD}${DOCKER_PROXY_URL}${RESET}"
  [[ -z "$DOCKER_MIRROR_URL" ]] || echo -e "  Mirror      : ${BOLD}${DOCKER_MIRROR_URL}${RESET}"
  echo ""
  echo -e "  Docker has been verified for this user without sudo."
  echo -e "  You can start using Docker as ${DOCKER_USER} now."
}

confirm_overwrite() {
  local path="$1" description="$2"
  if privileged test -e "$path"; then
    warn "${description} already exists: $path"
    choose_overwrite_mode "$path"
  fi
  return 0
}

choose_overwrite_mode() {
  local path="$1" answer backup_path

  echo -e "  ${YELLOW}1) 直接覆盖 / Overwrite${RESET}"
  echo -e "  ${YELLOW}2) 备份后覆盖 / Backup then overwrite${RESET}"
  echo -e "  ${YELLOW}3) 退出脚本 / Exit script${RESET}"

  while true; do
    read -r -p "$(echo -e "  ${CYAN}Select action for ${path} [1/2/3]: ${RESET}")" answer
    case "$answer" in
      1)
        return 0
        ;;
      2)
        backup_path="${path}.bak.$(date +%Y%m%d%H%M%S)"
        privileged cp -a "$path" "$backup_path"
        ok "backup created: $backup_path"
        return 0
        ;;
      3)
        fail "script aborted by user"
        ;;
      *)
        warn "please enter 1, 2, or 3"
        ;;
    esac
  done
}

main() {
  trap cleanup_temp_apt_proxy EXIT

  echo -e "${BOLD}${CYAN}"
  cat <<'EOF'
  ============================================
         Docker Init Script for New VPS
  ============================================
EOF
  echo -e "${RESET}"
  echo -e "  中文说明:"
  echo -e "  - 检查当前环境，包括权限、Docker 安装状态和常见残留配置"
  echo -e "  - 创建 Docker 用户，并加入 docker 组，实现免 sudo 使用"
  echo -e "  - 可选配置本次安装使用的临时代理"
  echo -e "  - 可选配置 Docker 长期代理或镜像源"
  echo -e "  - 如果发现已有关键配置文件，会让你选择直接覆盖、备份后覆盖或退出脚本"
  echo ""
  echo -e "  English:"
  echo -e "  - Check system state, privileges, Docker installation, and leftover config"
  echo -e "  - Create a Docker user and add it to the docker group for passwordless Docker use"
  echo -e "  - Optionally use a temporary proxy for this installation only"
  echo -e "  - Optionally configure a persistent Docker proxy or registry mirror"
  echo -e "  - If important config files already exist, you can overwrite, backup then overwrite, or exit"
  echo ""

  confirm "Start initialization?" "y" || exit 0

  print_phase "[1/5] Pre-check"
  check_privilege
  detect_os
  prompt_docker_user
  prompt_check_path
  inspect_current_environment
  prompt_temp_proxy

  print_phase "[2/5] Install packages"
  write_temp_apt_proxy
  install_base_packages
  setup_docker_repo
  install_docker

  print_phase "[3/5] Create docker user"
  ensure_user_and_group

  print_phase "[4/5] Docker network options"
  prompt_docker_network_options
  configure_docker_network

  print_phase "[5/5] Verify"
  verify_installation
  print_summary
}

main "$@"
