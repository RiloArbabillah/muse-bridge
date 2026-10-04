# muse-bridge

Expose any AI agent worker as an **OpenAI-compatible API** — then plug it into
[9Router](https://github.com/9router) (or any OpenAI client) as a custom provider
via *Add OpenAI Compatible*.

```
remote 9Router ──POST /v1/chat/completions──▶  muse-bridge ──queue──▶ worker
                                                        │                  │
                                                        │  GET /muse/pending│
                                                        │  POST /muse/answer│
                                                        ◀──── answer ──────
```

The bridge is a dumb, reliable pipe: it queues the request, waits up to 240s,
and returns the worker's answer as a normal chat completion (streaming
supported). The **worker** is where your AI lives — a script, an agent, or a
person behind a cron job.

## Prerequisites

Prepare these before you start (5–10 minutes):

| Need | Details |
|---|---|
| A machine for the bridge | VPS (Debian/Ubuntu with root SSH) **or** any always-on computer (Windows/macOS/Linux). The bridge itself uses ~30 MB RAM. |
| Python 3 | 3.8+; `install.sh` installs it on Debian/Ubuntu, on Windows get it from python.org (tick "Add to PATH") |
| Public reachability | One of: public IP + open firewall port `8765`, a domain + reverse proxy (Caddy/Nginx) with TLS, or `cloudflared tunnel` (free, no open ports) |
| Git | to clone this repo |
| A worker | something to answer the queue: `worker_example.py` + any OpenAI-compatible backend (its URL, API key, model id) — or your own agent implementing `GET /muse/pending` → `POST /muse/answer` |
| A 9Router (or any OpenAI client) | consumes the bridge via *Add OpenAI Compatible* |

Both the bridge **and** whatever exposes it (cloudflared / reverse proxy) must
stay running. If either stops, clients get connection errors — nothing breaks
permanently, just start them again. Note that `cloudflared` quick-tunnel URLs
change on every restart; use a named tunnel (free, needs a Cloudflare account)
for a stable URL.

## Quick start (VPS, Debian/Ubuntu)

```bash
git clone https://github.com/Rivaldiekaptr/muse-bridge.git /opt/muse-bridge-src
cd /opt/muse-bridge-src
sudo ./install.sh        # installs to /opt/muse-bridge, generates API keys
```

`install.sh` prints two API keys **once** — save them:
- **user key** → paste into 9Router as the provider API key
- **worker key** → give to whatever answers the queue (see below)

Then expose the bridge publicly (pick one):
- **Direct**: open port `8765` in the firewall, point 9Router at `http://YOUR-IP:8765/v1`
  (use a reverse proxy with TLS for anything serious)
- **Cloudflare Tunnel** (free, no open ports):
  `cloudflared tunnel --url http://127.0.0.1:8765`
  → base URL becomes `https://<id>.trycloudflare.com/v1`
- **Reverse proxy**: Caddy/Nginx in front of `127.0.0.1:8765` with your domain + TLS

## 9Router setup

*Add OpenAI Compatible* with:
| Field | Value |
|---|---|
| Name | anything, e.g. `Muse` |
| Prefix | anything **except** `muse` (it collides with 9Router's built-in provider id) |
| API Type | Chat Completions |
| Base URL | `https://YOUR-HOST/v1` |
| API Key | the **user** key from install |
| Model ID | `muse` (or leave empty — `/v1/models` is supported) |

Use *Test Connection*, then chat with `<prefix>/muse`.

## The worker

Anything that can do HTTPS can be a worker. Protocol (all need
`Authorization: Bearer <worker-key>`):

| Endpoint | Meaning |
|---|---|
| `GET /muse/pending?limit=5` | atomically claim up to 5 jobs (180s lease each) |
| `POST /muse/answer` `{"id","content"}` | answer a claimed job |
| `POST /muse/release` `{"id"}` | give a job back to the queue |
| `GET /health` | no auth, for monitoring |

`worker_example.py` is a ready-made reference: it polls `/muse/pending` and
answers each job through any OpenAI-compatible backend:

```bash
export BRIDGE_URL="http://127.0.0.1:8765"
export BRIDGE_WORKER_KEY="<worker key>"
export BACKEND_URL="http://127.0.0.1:20128/v1"   # e.g. your 9Router
export BACKEND_KEY="<backend key>"
export BACKEND_MODEL="your-provider/your-model"
python3 worker_example.py
```

Point `BACKEND_*` at an agentic CLI wrapper, an LLM API, or your own agent
loop — the bridge doesn't care, it just delivers the `content` string.

Key management: `python3 bridge.py keygen --role user|worker --label <name>`
(prints once), `keylist` (prefixes only), `keydel <prefix|label>`.

## Windows quick start

```powershell
$env:BRIDGE_QUEUE="C:\muse-bridge\queue"
python C:\muse-bridge\bridge.py keygen --role user --label 9router
python C:\muse-bridge\bridge.py keygen --role worker --label worker-1
python C:\muse-bridge\bridge.py          # serves on 127.0.0.1:8765
```
Then expose with `cloudflared tunnel --url http://127.0.0.1:8765`.
Note: `$env:` only applies to the current PowerShell session — always start
the bridge from a terminal where `BRIDGE_QUEUE` is set (verify with `keylist`).

## Endpoints

- `POST /v1/chat/completions` — OpenAI chat completions (streaming supported),
  waits up to 240s for the worker; `429` when the queue is full, `504` on timeout
- `GET /v1/models` — lists `muse`
- `GET /health` — `{"ok": true}`, no auth

## Security notes

- Never commit `keys.json` or `queue/` (see `.gitignore`); keys live only on
  the bridge host, mode 600.
- The bridge has no rate limiting beyond a 5-job queue cap — put it behind
  auth (it has bearer keys per role) and don't expose the machine's 9Router
  dashboard (it has no password by default).
- Rotate a key with `keydel` + `keygen` if it ever leaks.

## License

MIT — see [LICENSE](LICENSE).
