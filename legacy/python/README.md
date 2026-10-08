# Personal Claude usage tracker

A tiny macOS menu-bar app showing your **personal** Claude account's 5-hour
session and weekly usage — the numbers you can't otherwise see, because your
personal sessions run through `~/.claude-personal` (a `setup-token`) instead of
the work login the colleague's tracker app reads.

```
Claude  S 39% · W 50%        ← menu bar
  5-hour session: 39%  (resets in 4h 6m)
  Weekly: 50%  (resets in 22h 6m)
```

## How it gets the data (and why it's done this way)

The colleague's `Claude Usage Tracker.app` reads the OAuth token from the macOS
**Keychain** = the **work** account, and calls `GET /api/oauth/usage`.

Two dead ends for the personal account:
1. The personal `setup-token` is **inference-scoped** — `/api/oauth/usage`
   rejects it (needs `user:profile`).
2. An interactive OAuth login for this account fails at the authorize step
   ("Invalid request format"), so we can't mint a `user:profile` token either.

The trick: **every inference call returns the limit state in its response
headers**, and inference is exactly what the setup-token *can* do. So this tool
makes one tiny throwaway message (`max_tokens=1`, Haiku) and reads:

```
anthropic-ratelimit-unified-5h-utilization / -5h-reset / -5h-status   (session)
anthropic-ratelimit-unified-7d-utilization / -7d-reset / -7d-status   (weekly)
anthropic-ratelimit-unified-status                                    (overall)
```

No login, no extra credentials — it reuses `~/.claude-personal/token`. The probe
costs ~23 Haiku tokens, which is noise against the limits it reports.

## Setup

```sh
cd ~/.claude-personal/usage-tracker
./claude-usage --print        # sanity check: prints your usage right now
./install-login-item.sh       # run the menu-bar app now + at every login
```

No login step. If the token is ever rejected (you'll see a 401 message), just
re-run `claude setup-token` and overwrite `~/.claude-personal/token`; the tracker
re-reads the file on every refresh.

## Usage

```sh
./claude-usage               # menu-bar app in the foreground
./claude-usage --print       # print once (scriptable: prompt, tmux, /loop)
```

The menu bar shows `S <session>% · W <weekly>%`; click for reset times, any
non-`allowed` status, last-updated time, "Refresh now", and "Quit". It re-probes
every 5 minutes.

## Files

| file | purpose |
|------|---------|
| `core.py` | reads the token, makes the probe, parses the rate-limit headers |
| `tracker.py` | menu-bar app + `--print` CLI |
| `claude-usage` | launcher wrapper (uses the bundled venv) |
| `install-login-item.sh` | install the start-at-login LaunchAgent |
| `.venv/` | isolated Python 3.11 env (rumps + pyobjc) |

## Remove

```sh
launchctl unload ~/Library/LaunchAgents/com.wallace.claude-personal-usage.plist
rm ~/Library/LaunchAgents/com.wallace.claude-personal-usage.plist
rm -rf ~/.claude-personal/usage-tracker
```
