#!/usr/bin/env python3
"""
Personal Claude usage tracker — menu-bar app + CLI.

Modes:
  tracker.py            launch the menu-bar app (default)
  tracker.py --print    fetch + print usage once, then exit (scriptable)

Usage is read from the rate-limit headers of a tiny inference call made with the
existing ~/.claude-personal/token — no login required. See core.py.
"""

import sys
import time
from datetime import datetime, timezone

import core


# --------------------------------------------------------------------------- #
# Formatting
# --------------------------------------------------------------------------- #
def fmt_reset(epoch: int | None) -> str:
    if not epoch:
        return ""
    secs = int(epoch - time.time())
    if secs <= 0:
        return "resetting now"
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"resets in {d}d {h}h"
    if h:
        return f"resets in {h}h {m}m"
    return f"resets in {m}m"


def bucket_line(b: dict) -> str:
    reset = fmt_reset(b["reset_epoch"])
    tail = f"  ({reset})" if reset else ""
    warn = "" if b.get("status") in (None, "allowed") else f"  [{b['status']}]"
    return f"{b['label']}: {b['pct']:.0f}%{tail}{warn}"


def headline(parsed: dict) -> str:
    """Minimal menu-bar title: gauge glyph + 5-hour session %."""
    by = {b["key"]: b for b in parsed["buckets"]}
    if "five_hour" in by:
        return f"◔ {by['five_hour']['pct']:.0f}%"
    if parsed["buckets"]:
        return f"◔ {parsed['buckets'][0]['pct']:.0f}%"
    return "◔ —"


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def cli_print() -> None:
    try:
        parsed = core.fetch_usage()
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
    if not parsed["buckets"]:
        print("No usage buckets reported.")
    for b in parsed["buckets"]:
        print(bucket_line(b))
    if parsed.get("overall") and parsed["overall"] != "allowed":
        print(f"Overall status: {parsed['overall']}")


# --------------------------------------------------------------------------- #
# Menu-bar app
# --------------------------------------------------------------------------- #
def run_menubar() -> None:
    import rumps

    class UsageApp(rumps.App):
        def __init__(self):
            super().__init__("Claude", title="◔ …", quit_button=None)
            self.menu = ["(loading…)"]
            self.timer = rumps.Timer(self.refresh, 300)  # re-probe every 5 min
            self.timer.start()
            self.refresh(None)

        def _rebuild(self, title, detail_lines):
            self.title = title
            self.menu.clear()
            for line in detail_lines:
                item = rumps.MenuItem(line)
                item.set_callback(None)  # non-clickable info row
                self.menu.add(item)
            self.menu.add(rumps.separator)
            self.menu.add(rumps.MenuItem("Refresh now", callback=self.refresh))
            self.menu.add(rumps.separator)
            self.menu.add(rumps.MenuItem("Quit", callback=rumps.quit_application))

        def refresh(self, _):
            try:
                parsed = core.fetch_usage()
            except Exception as e:
                self._rebuild("⚠︎", [str(e)])
                return
            lines = [bucket_line(b) for b in parsed["buckets"]] or ["No active limits"]
            if parsed.get("overall") and parsed["overall"] != "allowed":
                lines.append(f"Overall: {parsed['overall']}")
            stamp = datetime.now(timezone.utc).astimezone().strftime("%H:%M")
            lines.append(f"updated {stamp}")
            self._rebuild(headline(parsed), lines)

    UsageApp().run()


def main() -> None:
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg in ("--print", "print", "--once"):
        cli_print()
    else:
        run_menubar()


if __name__ == "__main__":
    main()
