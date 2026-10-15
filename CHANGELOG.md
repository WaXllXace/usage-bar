# Changelog

## 1.0.0

First shareable release, renamed from "Claude Usage" to **Usage Bar**.

- Profiles are user-managed: add / edit / remove / reorder in ⚙︎ › Manage
  Profiles…, stored in `~/.config/usage-bar/profiles.json`. First launch
  auto-detects Claude Code (`~/.claude`, `~/.claude-*`) and Codex (`~/.codex`)
  logins; “Detect logins” re-scans.
- Per-profile colour, visibility and (Claude) token auto-refresh.
- Claude Code: reads the Keychain login for any `CLAUDE_CONFIG_DIR`, shows
  session, weekly and model-scoped weekly limits (Fable / Opus / …) as the
  usage API reports them for your plan.
- Codex CLI: reads `auth.json`, shows the plan’s rate-limit windows, account
  and credits.
- Menu bar rings + percentages, animated gauges, reset countdowns, launch at
  login, diagnostics log.
