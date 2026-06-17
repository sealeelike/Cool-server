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
PUBLIC_IP=$(curl -sf --max-time 5 https://ifconfig.me \
         || curl -sf --max-time 5 https://api.ipify.org \
         || curl -sf --max-time 5 https://ipecho.net/plain)

if [[ -z "$PUBLIC_IP" ]]; then
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

trap 'echo; echo "[*] Stopping iperf3..."; kill $IPERF_PID 2>/dev/null; wait $IPERF_PID 2>/dev/null; echo "[✓] iperf3 stopped."; exit 0' INT TERM

echo "[✓] iperf3 server started  PID=$IPERF_PID  port=$PORT"

# ─── print windows client commands ───────────────────────────────────────────
cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Run any of the following commands in Windows PowerShell:
  Requires iperf3 on Windows → https://files.budman.pw/
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# download speed  (server → client, single stream)
iperf3 -c $PUBLIC_IP -p $PORT -R

# download speed  (server → client, 4 parallel streams — more accurate on fast links)
iperf3 -c $PUBLIC_IP -p $PORT -R -P 4

# upload speed    (client → server, 4 parallel streams)
iperf3 -c $PUBLIC_IP -p $PORT -P 4

# bidirectional   (download + upload simultaneously, requires iperf3 >= 3.7)
iperf3 -c $PUBLIC_IP -p $PORT --bidir -P 4

# UDP jitter & packet loss  (download, target 5 Mbps — adjust -b as needed)
iperf3 -c $PUBLIC_IP -p $PORT -R -u -b 5M

# longer test     (30 s download, 4 streams — better average on unstable lines)
iperf3 -c $PUBLIC_IP -p $PORT -R -P 4 -t 30

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF

echo "[*] Press Ctrl+C to stop."
wait $IPERF_PID
