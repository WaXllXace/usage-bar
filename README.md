# Usage Bar

A small native macOS menu-bar app (SwiftUI, no webview, ~1 MB) that shows how
much of your **Claude Code** and **OpenAI Codex CLI** rate limits you have used.
Every login on the Mac can be tracked as its own profile — a work and a
personal Claude account, a shared Codex account, and so on.

![preview](assets/preview.png)

- **Menu bar**: one mini ring per profile (arc = headline usage, tinted with
  the profile colour, red at ≥ 80 %) plus the percentage. Three styles.
- **Popover**: a card per profile with an animated gauge for the 5-hour
  session, bars for the weekly limits (all models, Fable / Opus / Sonnet …),
  reset countdowns, plan badge, account, credits and limit status. Whatever
  limits your plan has are what you see — nothing is hard-coded per tier.
- **Profiles window**: add / edit / remove / reorder profiles, pick the config
  directory, colour, visibility, and (for Claude) token auto-refresh. “Detect
  logins” finds existing logins automatically.
- ⚙︎ menu: quick show/hide per profile, menu-bar style, refresh interval
  (1–15 min), launch at login.

## Install

Requires macOS 14 (Sonoma) or newer.

1. Download `UsageBar-<version>.zip` from the latest
   [release](../../releases), unzip, move **Usage Bar.app** to `~/Applications`
   (or `/Applications`).
2. The app is not notarized. The first time, **right-click → Open** and confirm
   (or allow it in System Settings › Privacy & Security). Only needed once.
3. On first launch it scans for logins (`~/.claude`, `~/.claude-*`,
   `~/.codex`) and shows a card for each. Open ⚙︎ › *Manage Profiles…* to
   rename, recolour, add or remove profiles, and ⚙︎ › *Launch at login* to keep
   it running.

If the menu bar shows `!` for a profile, open the popover — the card says
what is wrong (usually “sign in with `claude` / `codex` first”).

### Build from source

```sh
git clone <this repo> && cd usage-bar
scripts/bundle.sh     # swift build -c release → build/Usage Bar.app
scripts/install.sh    # copies to ~/Applications and launches it
```

Needs Xcode 15+ (or the command-line tools with a Swift 5.9 toolchain).
`scripts/release.sh` builds the zip for a GitHub release; set `SIGN_IDENTITY`
to a Developer ID to sign properly instead of ad-hoc.

## Profiles

Profiles live in `~/.config/usage-bar/profiles.json` and can be edited in the
app or by hand:

```json
[
  {"id": "work",     "name": "Work",     "provider": "claude", "configDir": "~/.claude",          "accent": "#4F7CF0", "enabled": true, "autoRefresh": true},
  {"id": "personal", "name": "Personal", "provider": "claude", "configDir": "~/.claude-personal", "accent": "#D97757", "enabled": true, "autoRefresh": true},
  {"id": "codex",    "name": "Codex",    "provider": "codex",  "configDir": "~/.codex",           "accent": "#10A37F", "enabled": true}
]
```

| field         | meaning |
|---------------|---------|
| `provider`    | `claude` (Claude Code) or `codex` (Codex CLI) |
| `configDir`   | Claude: the `CLAUDE_CONFIG_DIR` of that login (default `~/.claude`). Codex: the `CODEX_HOME` (default `~/.codex`) |
| `accent`      | hex colour used for the ring and card |
| `enabled`     | show in the menu bar and popover |
| `autoRefresh` | Claude only — refresh an expired access token yourself (see below) |

Multiple Claude accounts on one Mac work by launching the CLI with a different
`CLAUDE_CONFIG_DIR` for each (e.g. `CLAUDE_CONFIG_DIR=~/.claude-personal claude`).
Each such directory gets its own Keychain login and can be its own profile here.

## How it gets the data

### Claude Code

Claude Code stores its OAuth login in the macOS Keychain under a service name
derived from the config directory:

| config dir   | Keychain service |
|--------------|------------------|
| `~/.claude`  | `Claude Code-credentials` |
| anything else | `Claude Code-credentials-<first 8 hex of sha256(dir)>` |

The app reads that item (through `/usr/bin/security`, the same binary the CLI
uses, so no extra Keychain prompt) and calls
`GET https://api.anthropic.com/api/oauth/usage` — zero inference cost. The
response lists the 5-hour session, the weekly limit and any model-scoped
weekly limits (`limits[]`, e.g. Fable or Opus), which differ by plan; the app
renders whatever is there. Logins that only have the inference scope (old
`setup-token` files) fall back to a 1-token Haiku call and read the
`anthropic-ratelimit-unified-*` headers.

Logins made through the Claude desktop app (not the CLI) and plain API keys
have no readable quota and cannot be tracked.

**Token auto-refresh.** Access tokens expire after a few hours and the CLI
only refreshes them while it is running. With `autoRefresh` on (default) the
app refreshes an expired token itself using the stored refresh token — the
same request the CLI makes — and writes the result back to the Keychain item
in the same format. Caveat: refresh tokens rotate, so if a CLI process that
has the old token in memory refreshes at the same time, the server may reject
one of them and that profile needs a fresh `/login`. If that bothers you, turn
auto-refresh off for the profile; the card then asks you to run `claude` when
the token has expired.

### Codex CLI

`~/.codex/auth.json` holds a ChatGPT-login access token (a ~10-day JWT that
the CLI refreshes itself on every run). The app reads it and calls
`GET https://chatgpt.com/backend-api/wham/usage` with the `ChatGPT-Account-Id`
header, showing `rate_limit.primary_window` / `secondary_window` (which
windows exist depends on the plan), the plan, the account email and the credit
balance. The app never refreshes this token; when it has expired the card says
so and running `codex` once fixes it. API-key logins have no quota.

## Troubleshooting

- Diagnostics: `~/Library/Logs/UsageBar.log` (also in Console.app under
  subsystem `com.wallacehsieh.UsageBar`).
- `--demo` runs with fake data; `--render-preview out.png` writes the popover
  as a PNG.

## Layout

```
Sources/UsageBar/
  App.swift            MenuBarExtra(.window) + Profiles window
  Store.swift          profiles (CRUD, persistence), state, timer, menu-bar image
  Models.swift         Profile (Codable), profile file, login detection, buckets
  Credentials.swift    Claude Keychain via `security`, OAuth refresh, token-file fallback
  UsageClient.swift    Anthropic /api/oauth/usage + probe-header fallback
  CodexClient.swift    ~/.codex/auth.json + chatgpt.com wham/usage
  MenuBarLabel.swift   NSImage renderer for the status item
  Views/               PopoverView, ProfileCard, Gauges, ProfilesWindow
legacy/                earlier single-profile Rust and Python trackers
```
