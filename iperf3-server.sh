#!/usr/bin/env bash
set -euo pipefail

# ─── install iperf3 if missing ────────────────────────────────────────────────
if ! command -v iperf3 &>/dev/null; then
    echo "[*] Installing iperf3..."
    if command -v apt-get &>/dev/null; then
        dpkg --configure -a
        apt-get update
        apt-get install -y iperf3
    elif command -v dnf &>/dev/null; then
        dnf install -y iperf3
    elif command -v yum &>/dev/null; then
        yum install -y iperf3
    else
        echo "[!] Unsupported package manager. Install iperf3 manually." >&2
        exit 1
    fi
fi

# ─── get public ip ────────────────────────────────────────────────────────────
PUBLIC_IPV4=$(curl -4 -sf --max-time 5 https://api.ipify.org \
           || curl -4 -sf --max-time 5 https://ip.sb \
           || curl -4 -sf --max-time 5 https://icanhazip.com \
           || curl -4 -sf --max-time 5 https://ifconfig.me \
           || true)

PUBLIC_IPV6=$(curl -6 -sf --max-time 5 https://api6.ipify.org \
           || curl -6 -sf --max-time 5 https://ip.sb \
           || curl -6 -sf --max-time 5 https://icanhazip.com \
           || curl -6 -sf --max-time 5 https://ifconfig.me \
           || true)

PUBLIC_IPV4=$(echo "$PUBLIC_IPV4" | tr -d '[:space:]')
PUBLIC_IPV6=$(echo "$PUBLIC_IPV6" | tr -d '[:space:]')

if [[ -z "$PUBLIC_IPV4" && -z "$PUBLIC_IPV6" ]]; then
    echo "[!] Could not detect public IP." >&2
    exit 1
fi

# ─── port selection ─────────────────────────────────────────────────────
random_free_port() {
    while true; do
        local p=$(shuf -i 10000-65000 -n 1)
        ss -tlnH 2>/dev/null | awk '{print $4}' | grep -q ":${p}$" || { echo $p; return; }
    done
}

while true; do
    read -e -p "Port [Enter=5201, r=random, 1-65535=custom]: " _input
    _input="${_input:-5201}"
    if [[ "$_input" =~ ^[rR]$ ]]; then
        PORT=$(random_free_port)
        echo "[✓] Using random port: $PORT"
        break
    elif [[ "$_input" =~ ^[0-9]+$ ]] && (( _input >= 1 && _input <= 65535 )); then
        PORT=$_input
        break
    else
        echo "[!] Invalid input, try again."
    fi
done

# ─── start iperf3 server ──────────────────────────────────────────────────────
pkill -x iperf3 &>/dev/null || true

# 重定向 iperf3 的 stdout，避免监听信息抢占终端输出
iperf3 -s -p "$PORT" >/dev/null 2>&1 &
IPERF_PID=$!

# 等 iperf3 启动完成再打印信息
sleep 1

trap 'echo; echo "[*] Stopping iperf3..."; kill $IPERF_PID 2>/dev/null; wait $IPERF_PID 2>/dev/null; echo "[✓] iperf3 stopped."; exit 0' INT TERM HUP

echo "[✓] iperf3 server started  PID=$IPERF_PID  port=$PORT"

# ─── print windows client commands ───────────────────────────────────────────
print_pair() {
    local args="$1"

    [[ -n "$PUBLIC_IPV4" ]] && printf 'iperf3 -4 -c %s -p %s %s\n' "$PUBLIC_IPV4" "$PORT" "$args"
    [[ -n "$PUBLIC_IPV6" ]] && printf 'iperf3 -6 -c %s -p %s %s\n' "$PUBLIC_IPV6" "$PORT" "$args"
    return 0
}

cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Windows PowerShell commands
  Requires iperf3 on Windows → https://files.budman.pw/
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

echo
echo "# download speed  (server → client, single stream)"
print_pair "-R"

echo
echo "# download speed  (server → client, 4 parallel streams — more accurate on fast links)"
print_pair "-R -P 4"

echo
echo "# upload speed    (client → server, 4 parallel streams)"
print_pair "-P 4"

echo
echo "# bidirectional   (download + upload simultaneously, requires iperf3 >= 3.7)"
print_pair "--bidir -P 4"

echo
echo "# UDP jitter & packet loss  (download, target 5 Mbps — adjust -b as needed)"
print_pair "-R -u -b 5M"

echo
echo "# longer test     (30 s download, 4 streams — better average on unstable lines)"
print_pair "-R -P 4 -t 30"

cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF

echo "[*] Press Ctrl+C to stop."
wait $IPERF_PID
