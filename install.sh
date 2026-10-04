#!/usr/bin/env bash
# Quick install for a Debian/Ubuntu VPS. Run as root from the repo directory:
#   git clone https://github.com/Rivaldiekaptr/muse-bridge.git /opt/muse-bridge-src
#   cd /opt/muse-bridge-src && ./install.sh
set -euo pipefail

DEST="/opt/muse-bridge"
echo "[install] target: $DEST"

command -v python3 >/dev/null || { apt-get update && apt-get install -y python3; }

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
systemctl enable --now muse-bridge.service
echo "[install] muse-bridge is up: $(systemctl is-active muse-bridge.service)"
echo "[install] health check:"
curl -s http://127.0.0.1:8765/health; echo
echo
echo "[install] next: expose port 8765 (firewall / reverse proxy / cloudflared),"
echo "then run a worker: see README.md (worker_example.py)."
