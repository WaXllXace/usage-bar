import SwiftUI

// MARK: - Profiles

/// One Claude Code login (a CLAUDE_CONFIG_DIR). Credentials live in the macOS
/// Keychain under a service name derived from the config dir.
enum Provider: String, Hashable {
    case claude, codex
    var title: String { self == .claude ? "Claude" : "Codex" }
}

struct Profile: Identifiable, Hashable {
    let id: String
    var name: String
    var configDir: String
    var accent: Color
    var provider: Provider = .claude

    var displayDir: String {
        let home = NSHomeDirectory()
        return configDir.hasPrefix(home) ? "~" + configDir.dropFirst(home.count) : configDir
    }

    var initial: String { String(name.prefix(1)).uppercased() }

    static let defaults: [Profile] = [
        Profile(id: "work", name: "Work", configDir: NSHomeDirectory() + "/.claude",
                accent: Color(red: 0.31, green: 0.49, blue: 0.94)),
        Profile(id: "personal", name: "Personal", configDir: NSHomeDirectory() + "/.claude-personal",
                accent: Color(red: 0.85, green: 0.47, blue: 0.34)),
        Profile(id: "codex", name: "Engineer Shared", configDir: NSHomeDirectory() + "/.codex",
                accent: Color(red: 0.06, green: 0.64, blue: 0.50), provider: .codex),
    ]

    /// Optional override: ~/.config/claude-usage/profiles.json
    /// [{"id":"work","name":"Work","configDir":"~/.claude","accent":"#4F7CF0","provider":"claude"}, ...]
    static func load() -> [Profile] {
        let path = NSHomeDirectory() + "/.config/claude-usage/profiles.json"
        guard let data = FileManager.default.contents(atPath: path),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !arr.isEmpty else { return defaults }
        return arr.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String,
                  let dir = d["configDir"] as? String else { return nil }
            let expanded = (dir as NSString).expandingTildeInPath
            let accent = (d["accent"] as? String).flatMap(Color.init(hex:)) ?? .accentColor
            let provider = (d["provider"] as? String).flatMap(Provider.init(rawValue:)) ?? .claude
            return Profile(id: id, name: name, configDir: expanded, accent: accent, provider: provider)
        }
    }
}

// MARK: - Usage data

struct Bucket: Identifiable, Equatable {
    let key: String
    let label: String
    let percent: Double
    let resetsAt: Date?
    let status: String?
    var id: String { key }

    var isSession: Bool { key == "five_hour" }
    var isLimited: Bool { status != nil && status != "allowed" }

    static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "5-hour session"
        case "seven_day": return "Weekly · all models"
        case "seven_day_opus": return "Weekly · Opus"
        case "seven_day_sonnet": return "Weekly · Sonnet"
        case "seven_day_oauth_apps": return "Weekly · OAuth apps"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct Snapshot: Equatable {
    var buckets: [Bucket]
    var fetchedAt: Date
    var plan: String?
    var source: Source
    var account: String? = nil
    var extra: String? = nil

    enum Source: String { case api = "usage API", probe = "probe headers" }

    var session: Bucket? { buckets.first { $0.isSession } }
    var weekly: [Bucket] { buckets.filter { !$0.isSession } }
    var headline: Bucket? { session ?? buckets.first }

    /// Short caption under the ring's percentage.
    var ringCaption: String {
        guard let s = session else { return "" }
        let l = s.label.lowercased()
        if l.contains("week") { return "7d" }
        if let h = l.split(separator: "-").first, let n = Int(h) { return "\(n)h" }
        return "5h"
    }
}

enum ProfileState: Equatable {
    case idle
    case loading(last: Snapshot?)
    case ok(Snapshot)
    case error(String, last: Snapshot?)

    var snapshot: Snapshot? {
        switch self {
        case .idle: return nil
        case .loading(let s), .error(_, let s): return s
        case .ok(let s): return s
        }
    }
    var isLoading: Bool { if case .loading = self { return true } else { return false } }
    var errorText: String? { if case .error(let e, _) = self { return e } else { return nil } }
}

// MARK: - Severity colours

enum Severity {
    static func color(_ percent: Double) -> Color {
        switch percent {
        case ..<50: return Color(red: 0.20, green: 0.78, blue: 0.45)   // mint
        case ..<80: return Color(red: 1.00, green: 0.62, blue: 0.04)   // amber
        default:    return Color(red: 1.00, green: 0.27, blue: 0.23)   // red
        }
    }
    static func nsColor(_ percent: Double) -> NSColor { NSColor(color(percent)) }
}

// MARK: - Formatting helpers

enum Fmt {
    static func countdown(to date: Date, now: Date = .now) -> String {
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "resetting now" }
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "resets in \(d)d \(h)h" }
        if h > 0 { return "resets in \(h)h \(m)m" }
        return "resets in \(m)m"
    }

    static func clock(_ date: Date, now: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = date.timeIntervalSince(now) > 86400 ? "EEE HH:mm" : "HH:mm"
        return f.string(from: date)
    }

    static func ago(_ date: Date, now: Date = .now) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    static func plan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
