# Personal Claude usage tracker (Rust)

Native macOS menu-bar app showing your **personal** Claude account's 5-hour
session usage as `◔ NN%`, with weekly + reset times in the dropdown. Pure Rust,
no webview, no Python — a self-contained `.app` (~1.4 MB binary, ~32 MB RSS).

Replaces the earlier Python version (`../usage-tracker/`). Same data method.

## How it gets the data

The personal `setup-token` is inference-scoped and can't read `/api/oauth/usage`
(needs `user:profile`), and interactive OAuth login fails for this account. But
every inference call returns the limit state in its response headers. So the app
makes one tiny throwaway message (`max_tokens=1`, Haiku) with the token in
`~/.claude-personal/token` and reads:

```
anthropic-ratelimit-unified-5h-utilization / -5h-reset / -5h-status   (session)
anthropic-ratelimit-unified-7d-utilization / -7d-reset / -7d-status   (weekly)
```

Probe cost ≈ 23 Haiku tokens, re-run every 5 minutes. No login, no creds file.

## Build & install

```sh
cd ~/.claude-personal/usage-tracker-rs
./bundle.sh        # cargo build --release + assemble the .app
./install.sh       # LaunchAgent: run now + at every login
```

Needs the Rust toolchain (`~/.cargo`). If the token 401s, re-run
`claude setup-token` and overwrite `~/.claude-personal/token`.

## Stack

- `tao` — event loop + macOS accessory (no Dock icon)
- `tray-icon` — menu-bar item + menu
- `ureq` (rustls) — tiny blocking HTTP, no OpenSSL
- `serde_json` — parse the `.credentials.json` token fallback

`src/main.rs` is the whole app. Layout: read token → probe → parse headers →
update tray title + menu on the main thread (network runs on a worker thread,
results delivered via an `EventLoopProxy` user event).

## Remove

```sh
launchctl unload ~/Library/LaunchAgents/com.wallace.claude-personal-usage.plist
rm ~/Library/LaunchAgents/com.wallace.claude-personal-usage.plist
rm -rf ~/.claude-personal/usage-tracker-rs
```
