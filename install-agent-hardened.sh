#!/usr/bin/env bash
# ============================================================
#  Nezha Agent 加固安装脚本（Privilege-Drop Installer）
#  - 专用低权限用户
#  - config.yml 安装后锁为只读
#  - systemd 安全加固 + 资源限制
# ============================================================
set -euo pipefail

# ══════════════════════════════════════════════════════════════
#  伪装配置：修改此区块可隐藏 nezha 相关字样
#  所有运行时名称（进程、用户、目录、服务）均从这里派生
# ══════════════════════════════════════════════════════════════
DISGUISE_NAME="node-agent"            # 进程名 / 目录名 / 服务名
AGENT_USER="svc-${DISGUISE_NAME}"     # 系统用户名
AGENT_DIR="/opt/${DISGUISE_NAME}"     # 安装目录
SERVICE_DESC="Node Agent"             # systemd Description（ps 看不到，但 status 可见）
# ══════════════════════════════════════════════════════════════

CONFIG_FILE="${AGENT_DIR}/config.yml"
BINARY="${AGENT_DIR}/${DISGUISE_NAME}"
SERVICE_NAME="${DISGUISE_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ── 颜色输出 ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'
err()  { printf "${RED}[✗] %s${PLAIN}\n" "$*" >&2; }
ok()   { printf "${GREEN}[✓] %s${PLAIN}\n" "$*"; }
info() { printf "${YELLOW}[→] %s${PLAIN}\n" "$*"; }

# ── 必须 root ─────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || { err "请以 root 身份运行"; exit 1; }

# ── 架构检测 ──────────────────────────────────────────────────
detect_arch() {
    case $(uname -m) in
        x86_64|amd64)       echo "amd64"   ;;
        aarch64|arm64)      echo "arm64"   ;;
        armv7l|armv6l|arm*) echo "arm"     ;;
        s390x)              echo "s390x"   ;;
        riscv64)            echo "riscv64" ;;
        mips)               echo "mips"    ;;
        mipsel|mipsle)      echo "mipsle"  ;;
        loongarch64)        echo "loong64" ;;
        *) err "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

# ── 从粘贴的命令中提取变量 ────────────────────────────────────
parse_var() {
    echo "$2" | grep -o "${1}=[^ &]*" | cut -d= -f2- || true
}

# ══════════════════════════════════════════════════════════════
echo ""
echo "  Nezha Agent 加固安装程序"
echo "══════════════════════════════════════════════════════"
echo ""
info "请从 Nezha 面板复制安装命令，粘贴后按 Enter："
echo ""
read -r RAW_CMD < /dev/tty

# 提取变量
NZ_SERVER=$(parse_var "NZ_SERVER" "$RAW_CMD")
NZ_CLIENT_SECRET=$(parse_var "NZ_CLIENT_SECRET" "$RAW_CMD")
NZ_UUID=$(parse_var "NZ_UUID" "$RAW_CMD")
NZ_TLS=$(parse_var "NZ_TLS" "$RAW_CMD")
NZ_TLS=${NZ_TLS:-true}

# 校验必填项
[ -n "$NZ_SERVER" ]        || { err "无法解析 NZ_SERVER";        exit 1; }
[ -n "$NZ_CLIENT_SECRET" ] || { err "无法解析 NZ_CLIENT_SECRET"; exit 1; }

# 确认
echo ""
info "解析结果："
printf "    %-18s %s\n" "SERVER"        "$NZ_SERVER"
printf "    %-18s %s\n" "CLIENT_SECRET" "${NZ_CLIENT_SECRET:0:8}••••••••"
printf "    %-18s %s\n" "UUID"          "${NZ_UUID:-（未指定，自动分配）}"
printf "    %-18s %s\n" "TLS"           "$NZ_TLS"
echo ""
info "运行时伪装名称：${DISGUISE_NAME}  用户：${AGENT_USER}  目录：${AGENT_DIR}"
echo ""
read -rp "  确认以上信息，继续安装？[Y/n] " CONFIRM < /dev/tty
CONFIRM=${CONFIRM:-y}
[[ "${CONFIRM,,}" == "y" ]] || { info "已取消"; exit 0; }
echo ""

# ── 停止旧服务（如有）────────────────────────────────────────
for OLD in nezha-agent "${SERVICE_NAME}"; do
    if systemctl is-active --quiet "$OLD" 2>/dev/null; then
        info "停止已有 ${OLD} 服务..."
        systemctl stop "$OLD"
    fi
    if systemctl is-enabled --quiet "$OLD" 2>/dev/null; then
        systemctl disable "$OLD"
    fi
done

# ── 下载二进制 ────────────────────────────────────────────────
ARCH=$(detect_arch)
ZIP_URL="https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_${ARCH}.zip"
TMP_DIR=$(mktemp -d)
TMP_ZIP="${TMP_DIR}/agent.zip"

info "下载 agent (linux/${ARCH})..."
if command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP_ZIP" "$ZIP_URL"
elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$TMP_ZIP" "$ZIP_URL"
else
    err "未找到 wget 或 curl"; exit 1
fi
ok "下载完成"

# ── 创建专用用户 ──────────────────────────────────────────────
if ! id "$AGENT_USER" &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -M -d "$AGENT_DIR" "$AGENT_USER"
    ok "用户 ${AGENT_USER} 已创建"
else
    info "用户 ${AGENT_USER} 已存在，跳过"
fi

# ── 安装二进制（解压后改名）──────────────────────────────────
mkdir -p "$AGENT_DIR"
unzip -qo "$TMP_ZIP" -d "$TMP_DIR"
rm -f "$TMP_ZIP"

# zip 内的原始二进制固定叫 nezha-agent，解压后改为伪装名
mv "${TMP_DIR}/nezha-agent" "$BINARY"
rm -rf "$TMP_DIR"

# root 拥有，任何人可执行，AGENT_USER 无法替换或删除
chown root:root "$BINARY"
chmod 755 "$BINARY"
ok "二进制已安装 → ${BINARY}"

# ── 写入 config.yml 并锁定 ────────────────────────────────────
cat > "$CONFIG_FILE" <<EOF
client_secret: ${NZ_CLIENT_SECRET}
server: ${NZ_SERVER}
tls: ${NZ_TLS}
EOF
[ -n "$NZ_UUID" ] && echo "uuid: ${NZ_UUID}" >> "$CONFIG_FILE"

# root 拥有，AGENT_USER 只读，其他人不可见
chown root:"$AGENT_USER" "$CONFIG_FILE"
chmod 640 "$CONFIG_FILE"
ok "config.yml 已写入并锁定（${AGENT_USER} 只读）"

# 目录本身：root 拥有，AGENT_USER 无写权限
chown root:root "$AGENT_DIR"
chmod 755 "$AGENT_DIR"

# ── 写入加固 systemd service ──────────────────────────────────
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=${SERVICE_DESC}
After=network.target

[Service]
User=${AGENT_USER}
Group=${AGENT_USER}

ExecStart=${BINARY} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5

# ── 资源限制 ──────────────────────────────────────────────────
Nice=19
MemoryMax=50M
MemorySwapMax=0

# ── 禁止任何提权 ──────────────────────────────────────────────
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=

# ── 文件系统隔离 ──────────────────────────────────────────────
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes

# ── 其他限制 ──────────────────────────────────────────────────
RestrictNamespaces=yes
LockPersonality=yes
RestrictRealtime=yes
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
ok "systemd service 已写入 → ${SERVICE_FILE}"

# ── 启动 ──────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
ok "服务已启动"

echo ""
echo "══════════════════════════════════════════════════════"
ok "安装完成"
echo "══════════════════════════════════════════════════════"
echo ""
printf "  %-20s %s\n" "查看状态："  "systemctl status ${SERVICE_NAME}"
printf "  %-20s %s\n" "实时日志："  "journalctl -u ${SERVICE_NAME} -f"
echo ""
