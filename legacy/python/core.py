"""
Core usage logic for the personal Claude usage tracker.

Approach: the personal account's `setup-token` (sk-ant-oat01-…, inference scope)
CANNOT read the /api/oauth/usage endpoint (needs user:profile), and an
interactive OAuth login for this account fails ("Invalid request format").

BUT every real inference call returns the 5-hour and weekly limit state in its
response headers — and inference is exactly what the setup-token is allowed to
do. So we make one tiny throwaway message (max_tokens=1, Haiku) and read:

  anthropic-ratelimit-unified-5h-utilization / -5h-reset / -5h-status   (session)
  anthropic-ratelimit-unified-7d-utilization / -7d-reset / -7d-status   (weekly)
  anthropic-ratelimit-unified-status                                    (overall)

No login, no extra credentials — it reuses the token already in
~/.claude-personal/token. The probe costs ~23 Haiku tokens, which is noise
against the limits it reports.
"""

import json
import os
import urllib.error
import urllib.request

TOKEN_FILE = os.path.expanduser("~/.claude-personal/token")
CREDS_FILE = os.path.expanduser("~/.claude-personal/.credentials.json")
MESSAGES_URL = "https://api.anthropic.com/v1/messages"
PROBE_MODEL = "claude-haiku-4-5-20251001"
BETA = "oauth-2025-04-20"
UA = "claude-code/2.1.14"
# OAuth (subscription) tokens require the Claude Code identity in the system prompt.
SYSTEM = "You are Claude Code, Anthropic's official CLI for Claude."


def read_token() -> str | None:
    """Read the personal access token (re-read each call so a refreshed
    setup-token is picked up automatically)."""
    try:
        with open(TOKEN_FILE) as f:
            tok = f.read().strip()
            if tok:
                return tok
    except FileNotFoundError:
        pass
    try:
        with open(CREDS_FILE) as f:
            return json.load(f)["claudeAiOauth"]["accessToken"]
    except (FileNotFoundError, KeyError, json.JSONDecodeError):
        return None


def _probe() -> dict:
    """Make a minimal inference call and return its response headers."""
    token = read_token()
    if not token:
        raise RuntimeError(
            "No personal token found. Run `claude setup-token` and paste it "
            "into ~/.claude-personal/token."
        )
    payload = json.dumps(
        {
            "model": PROBE_MODEL,
            "max_tokens": 1,
            "system": SYSTEM,
            "messages": [{"role": "user", "content": "hi"}],
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        MESSAGES_URL,
        data=payload,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-version": "2023-06-01",
            "anthropic-beta": BETA,
            "content-type": "application/json",
            "User-Agent": UA,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            headers = resp.headers
            resp.read()  # drain
            return headers
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        if e.code == 401:
            raise RuntimeError(
                "Token rejected (401). Re-run `claude setup-token` and update "
                "~/.claude-personal/token."
            ) from None
        raise RuntimeError(f"HTTP {e.code}: {body[:200]}") from None


_H = "anthropic-ratelimit-unified-"
_BUCKETS = [
    ("five_hour", "5-hour session", "5h"),
    ("seven_day", "Weekly", "7d"),
]


def fetch_usage() -> dict:
    """Return {"buckets": [{key,label,pct,reset_epoch,status}], "overall": str}."""
    h = _probe()
    buckets = []
    for key, label, prefix in _BUCKETS:
        util = h.get(f"{_H}{prefix}-utilization")
        if util in (None, ""):
            continue
        reset = h.get(f"{_H}{prefix}-reset")
        buckets.append(
            {
                "key": key,
                "label": label,
                "pct": float(util) * 100.0,
                "reset_epoch": int(reset) if reset else None,
                "status": h.get(f"{_H}{prefix}-status"),
            }
        )
    return {"buckets": buckets, "overall": h.get(f"{_H}status")}
