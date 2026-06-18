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
PUBLIC_IPV4=$(curl -4 -sf --max-time 5 https://ip.sb\
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

iperf3 -s -p "$PORT" &
IPERF_PID=$!

trap 'echo; echo "[*] Stopping iperf3..."; kill $IPERF_PID 2>/dev/null; wait $IPERF_PID 2>/dev/null; echo "[✓] iperf3 stopped."; exit 0' INT TERM HUP

echo "[✓] iperf3 server started  PID=$IPERF_PID  port=$PORT"

# ─── print windows client commands ───────────────────────────────────────────
print_commands() {
    local label="$1"
    local ip="$2"
    local flag="$3"

    cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  $label test commands for Windows PowerShell
  Requires iperf3 on Windows → https://files.budman.pw/
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# download speed  (server → client, single stream)
iperf3 $flag -c $ip -p $PORT -R

# download speed  (server → client, 4 parallel streams — more accurate on fast links)
iperf3 $flag -c $ip -p $PORT -R -P 4

# upload speed    (client → server, 4 parallel streams)
iperf3 $flag -c $ip -p $PORT -P 4

# bidirectional   (download + upload simultaneously, requires iperf3 >= 3.7)
iperf3 $flag -c $ip -p $PORT --bidir -P 4

# UDP jitter & packet loss  (download, target 5 Mbps — adjust -b as needed)
iperf3 $flag -c $ip -p $PORT -R -u -b 5M

# longer test     (30 s download, 4 streams — better average on unstable lines)
iperf3 $flag -c $ip -p $PORT -R -P 4 -t 30

EOF
}

[[ -n "$PUBLIC_IPV4" ]] && print_commands "IPv4" "$PUBLIC_IPV4" "-4"
[[ -n "$PUBLIC_IPV6" ]] && print_commands "IPv6" "$PUBLIC_IPV6" "-6"

cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF

echo "[*] Press Ctrl+C to stop."
wait $IPERF_PID
