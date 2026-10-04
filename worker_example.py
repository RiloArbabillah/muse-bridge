#!/usr/bin/env python3
"""Reference worker for muse-bridge.

Polls the bridge's worker API, answers each claimed job with an
OpenAI-compatible backend, and posts the answer back.

This is the "AI" behind the bridge — point BACKEND_* at anything that speaks
the OpenAI chat-completions protocol (another 9Router, OpenAI, Ollama, ...),
or replace answer_job() with your own agent.

Config (env vars):
  BRIDGE_URL         e.g. http://127.0.0.1:8765            (required)
  BRIDGE_WORKER_KEY  key with role=worker (bridge.py keygen --role worker)
  BACKEND_URL        OpenAI-compatible base URL, e.g. http://127.0.0.1:20128/v1
  BACKEND_KEY        backend API key (may be empty)
  BACKEND_MODEL      model id for the backend, e.g. muse-bridge/muse
  POLL_SECS          poll interval, default 5

Stdlib only.
"""
import json
import os
import time
import urllib.request
import urllib.error

BRIDGE_URL = os.environ.get("BRIDGE_URL", "http://127.0.0.1:8765").rstrip("/")
WKEY = os.environ.get("BRIDGE_WORKER_KEY", "")
BACKEND_URL = os.environ.get("BACKEND_URL", "").rstrip("/")
BACKEND_KEY = os.environ.get("BACKEND_KEY", "")
BACKEND_MODEL = os.environ.get("BACKEND_MODEL", "")
POLL_SECS = int(os.environ.get("POLL_SECS", "5"))


def _call(url, key, payload, timeout=240):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if key:
        req.add_header("Authorization", "Bearer " + key)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def _bridge(path, payload=None, method="GET"):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BRIDGE_URL + path, data=data,
                                 method=method if payload is not None else "GET")
    req.add_header("Authorization", "Bearer " + WKEY)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"bridge {path} -> {e.code}: {e.read().decode()[:200]}")


def answer_job(job):
    """Turn a claimed bridge job into an answer string. Swap this out."""
    req = job.get("request", {})
    messages = req.get("messages", [])
    if not messages:
        return "Muse worker: empty request, nothing to answer."
    resp = _call(BACKEND_URL + "/chat/completions", BACKEND_KEY, {
        "model": BACKEND_MODEL,
        "messages": messages,
        "max_tokens": req.get("max_tokens", 4096),
        "stream": False,
    }, timeout=300)
    return resp["choices"][0]["message"]["content"]


def main():
    if not WKEY or not BACKEND_URL or not BACKEND_MODEL:
        raise SystemExit("set BRIDGE_WORKER_KEY, BACKEND_URL and BACKEND_MODEL env vars")
    print(f"worker polling {BRIDGE_URL} -> backend {BACKEND_URL} ({BACKEND_MODEL})",
          flush=True)
    while True:
        try:
            claimed = _bridge("/muse/pending?limit=3")
        except Exception as e:
            print(f"poll error: {e}", flush=True)
            time.sleep(POLL_SECS)
            continue
        for job in claimed.get("jobs", []):
            jid = job["id"]
            try:
                content = answer_job(job)
                _bridge("/muse/answer", {"id": jid, "content": content})
                print(f"answered {jid}", flush=True)
            except Exception as e:
                print(f"job {jid} failed ({e}); releasing", flush=True)
                try:
                    _bridge("/muse/release", {"id": jid})
                except Exception:
                    pass
        time.sleep(POLL_SECS)


if __name__ == "__main__":
    main()
