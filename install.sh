#!/usr/bin/env bash
# Quick install for a Debian/Ubuntu VPS. Run as root from the repo directory:
#   git clone https://github.com/Rivaldiekaptr/muse-bridge.git /opt/muse-bridge-src
#   cd /opt/muse-bridge-src && ./install.sh
set -euo pipefail

DEST="/opt/muse-bridge"
echo "[install] target: $DEST"

command -v python3 >/dev/null || { apt-get update && apt-get install -y python3; }
command -v curl >/dev/null || { apt-get update && apt-get install -y curl; }

# --- cloudflared (quick public tunnel; installed so "just works") ---------
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[install] installing cloudflared..."
  CF_ARCH=""
  case "$(uname -m)" in
    x86_64)        CF_ARCH=amd64 ;;
    aarch64|arm64) CF_ARCH=arm64 ;;
    *) echo "[install] unsupported arch $(uname -m) — install cloudflared manually" >&2 ;;
  esac
  if [ -n "$CF_ARCH" ]; then
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb" \
      -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb
    rm -f /tmp/cloudflared.deb
  fi
fi

mkdir -p "$DEST/queue"
cp bridge.py worker_example.py "$DEST/"
chmod 644 "$DEST/bridge.py" "$DEST/worker_example.py"

export BRIDGE_QUEUE="$DEST/queue"
if [ ! -f "$DEST/keys.json" ]; then
  echo "[install] generating API keys (shown once — save them now)..."
  echo "--- user key (for 9Router / OpenAI clients) ---"
  python3 "$DEST/bridge.py" keygen --role user --label 9router
  echo "--- worker key (for your worker) ---"
  python3 "$DEST/bridge.py" keygen --role worker --label worker-1
  echo "--- copy both keys somewhere safe before continuing ---"
fi

cp systemd/muse-bridge.service /etc/systemd/system/muse-bridge.service
systemctl daemon-reload
systemctl enable muse-bridge.service
# restart (not just --now): re-runs must pick up the new bridge.py
systemctl restart muse-bridge.service
echo "[install] muse-bridge is up: $(systemctl is-active muse-bridge.service)"
echo "[install] health check:"
sleep 2
curl -s --max-time 10 http://127.0.0.1:8765/health \
  || echo "(not responding yet — check: sudo journalctl -u muse-bridge -n 20)"
echo
echo "[install] starting persistent cloudflared tunnel (systemd)..."
CF_BIN="$(command -v cloudflared)"
sed "s|@CLOUDFLARED@|$CF_BIN|" systemd/cloudflared-muse-bridge.service \
  > /etc/systemd/system/cloudflared-muse-bridge.service
chmod 644 /etc/systemd/system/cloudflared-muse-bridge.service
systemctl daemon-reload
systemctl enable --now cloudflared-muse-bridge.service
echo "[install] tunnel service: $(systemctl is-active cloudflared-muse-bridge.service)"

# --- final summary: everything needed, in one place -------------------------
sleep 3
TUNNEL_URL=$(journalctl -u cloudflared-muse-bridge -n 100 --no-pager 2>/dev/null \
  | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | head -1)
echo
echo "=================================================================="
echo "  muse-bridge is ready! Save this:"
if [ -n "$TUNNEL_URL" ]; then
  echo "  Base URL  (9Router -> Add OpenAI Compatible):"
  echo "    ${TUNNEL_URL}/v1"
  echo "  (tunnel URL changes on restart;"
  echo "   disable tunnel: systemctl disable --now cloudflared-muse-bridge)"
else
  echo "  Base URL: tunnel not up yet — check: journalctl -u cloudflared-muse-bridge"
fi
echo "  API keys:"
python3 - "$DEST/keys.json" <<'PYEOF'
import json, sys
for k in json.load(open(sys.argv[1]))["keys"]:
    print(f"    [{k['role']}] label={k['label']}: {k['key']}")
PYEOF
echo "    -> put the [user] key into 9Router as the provider API key"
echo "    -> give the [worker] key to whoever answers the queue"
echo "=================================================================="
