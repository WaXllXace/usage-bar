// Personal Claude usage tracker — pure-Rust macOS menu-bar app.
//
// Same idea as the Python version: the personal setup-token is inference-scoped
// (can't read /api/oauth/usage), but every inference call returns the 5h/weekly
// limit state in its response headers. So we make one tiny throwaway message and
// read anthropic-ratelimit-unified-{5h,7d}-{utilization,reset,status}.
//
// No login, no extra credentials — reuses ~/.claude-personal/token.

use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy};
use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
use tray_icon::menu::{Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem};
use tray_icon::{TrayIcon, TrayIconBuilder};

const MESSAGES_URL: &str = "https://api.anthropic.com/v1/messages";
const PROBE_MODEL: &str = "claude-haiku-4-5-20251001";
const REFRESH_SECS: u64 = 300;

// ---------------------------------------------------------------------------
// Usage data
// ---------------------------------------------------------------------------
struct Bucket {
    key: &'static str,
    label: &'static str,
    pct: f64,
    reset: Option<i64>,
    status: Option<String>,
}

struct Usage {
    buckets: Vec<Bucket>,
    overall: Option<String>,
}

fn home() -> String {
    std::env::var("HOME").unwrap_or_default()
}

fn read_token() -> Option<String> {
    let token_file = format!("{}/.claude-personal/token", home());
    if let Ok(s) = std::fs::read_to_string(&token_file) {
        let t = s.trim();
        if !t.is_empty() {
            return Some(t.to_string());
        }
    }
    // Fallback: the accessToken inside .credentials.json.
    let creds = format!("{}/.claude-personal/.credentials.json", home());
    if let Ok(s) = std::fs::read_to_string(&creds) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&s) {
            if let Some(t) = v["claudeAiOauth"]["accessToken"].as_str() {
                return Some(t.to_string());
            }
        }
    }
    None
}

fn fetch() -> Result<Usage, String> {
    let token = read_token().ok_or(
        "No personal token found. Run `claude setup-token` and paste it into \
         ~/.claude-personal/token.",
    )?;
    let body = format!(
        r#"{{"model":"{PROBE_MODEL}","max_tokens":1,"system":"You are Claude Code, Anthropic's official CLI for Claude.","messages":[{{"role":"user","content":"hi"}}]}}"#
    );
    let resp = ureq::post(MESSAGES_URL)
        .set("Authorization", &format!("Bearer {token}"))
        .set("anthropic-version", "2023-06-01")
        .set("anthropic-beta", "oauth-2025-04-20")
        .set("content-type", "application/json")
        .set("User-Agent", "claude-code/2.1.14")
        .send_string(&body);

    let r = match resp {
        Ok(r) => r,
        Err(ureq::Error::Status(401, _)) => {
            return Err(
                "Token rejected (401). Re-run `claude setup-token` and update \
                 ~/.claude-personal/token."
                    .into(),
            )
        }
        Err(ureq::Error::Status(code, r)) => {
            let b = r.into_string().unwrap_or_default();
            return Err(format!("HTTP {code}: {}", &b[..b.len().min(200)]));
        }
        Err(e) => return Err(format!("network error: {e}")),
    };

    let mut buckets = Vec::new();
    for (key, label, prefix) in [
        ("five_hour", "5-hour session", "5h"),
        ("seven_day", "Weekly", "7d"),
    ] {
        let util_h = format!("anthropic-ratelimit-unified-{prefix}-utilization");
        if let Some(u) = r.header(&util_h) {
            if let Ok(util) = u.parse::<f64>() {
                let reset = r
                    .header(&format!("anthropic-ratelimit-unified-{prefix}-reset"))
                    .and_then(|s| s.parse::<i64>().ok());
                let status = r
                    .header(&format!("anthropic-ratelimit-unified-{prefix}-status"))
                    .map(str::to_string);
                buckets.push(Bucket {
                    key,
                    label,
                    pct: util * 100.0,
                    reset,
                    status,
                });
            }
        }
    }
    let overall = r.header("anthropic-ratelimit-unified-status").map(str::to_string);
    Ok(Usage { buckets, overall })
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------
fn now_epoch() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn fmt_reset(epoch: i64) -> String {
    let secs = epoch - now_epoch();
    if secs <= 0 {
        return "resetting now".into();
    }
    let (d, h, m) = (secs / 86400, (secs % 86400) / 3600, (secs % 3600) / 60);
    if d > 0 {
        format!("resets in {d}d {h}h")
    } else if h > 0 {
        format!("resets in {h}h {m}m")
    } else {
        format!("resets in {m}m")
    }
}

fn headline(u: &Usage) -> String {
    if let Some(b) = u.buckets.iter().find(|b| b.key == "five_hour") {
        return format!("◔ {:.0}%", b.pct);
    }
    if let Some(b) = u.buckets.first() {
        return format!("◔ {:.0}%", b.pct);
    }
    "◔ —".into()
}

fn detail_lines(u: &Usage) -> Vec<String> {
    let mut v: Vec<String> = u
        .buckets
        .iter()
        .map(|b| {
            let mut s = format!("{}: {:.0}%", b.label, b.pct);
            if let Some(r) = b.reset {
                s.push_str(&format!("  ({})", fmt_reset(r)));
            }
            if let Some(st) = &b.status {
                if st != "allowed" {
                    s.push_str(&format!("  [{st}]"));
                }
            }
            s
        })
        .collect();
    if v.is_empty() {
        v.push("No active limits".into());
    }
    if let Some(o) = &u.overall {
        if o != "allowed" {
            v.push(format!("Overall: {o}"));
        }
    }
    v
}

// ---------------------------------------------------------------------------
// UI plumbing
// ---------------------------------------------------------------------------
enum UserEvent {
    Tick,
    Menu(MenuId),
    Result(Result<Usage, String>),
}

/// Build a menu from info lines; returns it plus the Refresh/Quit ids.
fn build_menu(lines: &[String]) -> (Menu, MenuId, MenuId) {
    let menu = Menu::new();
    for line in lines {
        let _ = menu.append(&MenuItem::new(line, false, None)); // disabled info row
    }
    let _ = menu.append(&PredefinedMenuItem::separator());
    let refresh = MenuItem::new("Refresh now", true, None);
    let _ = menu.append(&refresh);
    let _ = menu.append(&PredefinedMenuItem::separator());
    let quit = MenuItem::new("Quit", true, None);
    let _ = menu.append(&quit);
    (menu, refresh.id().clone(), quit.id().clone())
}

fn spawn_refresh(proxy: EventLoopProxy<UserEvent>) {
    std::thread::spawn(move || {
        let _ = proxy.send_event(UserEvent::Result(fetch()));
    });
}

fn main() {
    let mut event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    event_loop.set_activation_policy(ActivationPolicy::Accessory); // no Dock icon

    // Forward menu clicks into the event loop.
    let menu_proxy = event_loop.create_proxy();
    MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
        let _ = menu_proxy.send_event(UserEvent::Menu(e.id));
    }));

    // Timer thread: tick now, then every REFRESH_SECS.
    let tick_proxy = event_loop.create_proxy();
    std::thread::spawn(move || loop {
        let _ = tick_proxy.send_event(UserEvent::Tick);
        std::thread::sleep(std::time::Duration::from_secs(REFRESH_SECS));
    });

    let loop_proxy = event_loop.create_proxy();
    let mut tray: Option<TrayIcon> = None;
    let mut refresh_id: Option<MenuId> = None;
    let mut quit_id: Option<MenuId> = None;

    event_loop.run(move |event, _target, control_flow| {
        *control_flow = ControlFlow::Wait;
        match event {
            // Tray must be created after the NSApplication is up (macOS).
            Event::NewEvents(StartCause::Init) => {
                let (menu, rid, qid) = build_menu(&["(loading…)".to_string()]);
                match TrayIconBuilder::new()
                    .with_menu(Box::new(menu))
                    .with_title("◔ …")
                    .build()
                {
                    Ok(t) => tray = Some(t),
                    Err(e) => eprintln!("tray build failed: {e}"),
                }
                refresh_id = Some(rid);
                quit_id = Some(qid);
            }
            Event::UserEvent(UserEvent::Tick) => spawn_refresh(loop_proxy.clone()),
            Event::UserEvent(UserEvent::Menu(id)) => {
                if quit_id.as_ref() == Some(&id) {
                    *control_flow = ControlFlow::Exit;
                } else if refresh_id.as_ref() == Some(&id) {
                    spawn_refresh(loop_proxy.clone());
                }
            }
            Event::UserEvent(UserEvent::Result(res)) => {
                let (title, lines) = match res {
                    Ok(u) => (headline(&u), detail_lines(&u)),
                    Err(e) => ("⚠︎".to_string(), vec![e]),
                };
                let (menu, rid, qid) = build_menu(&lines);
                if let Some(t) = &tray {
                    let _ = t.set_menu(Some(Box::new(menu)));
                    let _ = t.set_title(Some(&title));
                }
                refresh_id = Some(rid);
                quit_id = Some(qid);
            }
            _ => {}
        }
    });
}
