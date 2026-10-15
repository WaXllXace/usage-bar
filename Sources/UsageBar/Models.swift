import SwiftUI

// MARK: - Profiles

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
    var defaultDir: String { self == .claude ? "~/.claude" : "~/.codex" }
    var hint: String {
        switch self {
        case .claude: return "A Claude Code config dir (CLAUDE_CONFIG_DIR). Its login is read from the Keychain."
        case .codex: return "A Codex CLI home dir (CODEX_HOME) containing auth.json."
        }
    }
}

/// One tracked login. `path` may contain `~`; `configDir` is the expanded form.
struct Profile: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var path: String
    var accentHex: String
    var provider: Provider
    var enabled: Bool
    var autoRefresh: Bool

    init(id: String = UUID().uuidString, name: String, path: String, accentHex: String,
         provider: Provider = .claude, enabled: Bool = true, autoRefresh: Bool = true) {
        self.id = id; self.name = name; self.path = path; self.accentHex = accentHex
        self.provider = provider; self.enabled = enabled; self.autoRefresh = autoRefresh
    }

    enum CodingKeys: String, CodingKey { case id, name, path = "configDir", accentHex = "accent", provider, enabled, autoRefresh }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? provider.defaultDir
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? Palette.next(for: 0)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        autoRefresh = try c.decodeIfPresent(Bool.self, forKey: .autoRefresh) ?? true
    }

    var configDir: String { (path as NSString).expandingTildeInPath }
    var displayDir: String { (configDir as NSString).abbreviatingWithTildeInPath }
    var accent: Color { Color(hex: accentHex) ?? .accentColor }
    var initial: String { String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }

    /// Same login as another profile (used to de-duplicate detection results).
    func sameLogin(as other: Profile) -> Bool {
        provider == other.provider && (configDir as NSString).standardizingPath == (other.configDir as NSString).standardizingPath
    }
}

enum Palette {
    static let colors = ["#4F7CF0", "#D97757", "#10A37F", "#8E5CF6", "#E0A400", "#E3528B", "#2BB3C0"]
    static func next(for index: Int) -> String { colors[index % colors.count] }
    static func unused(by profiles: [Profile]) -> String {
        colors.first { c in !profiles.contains { $0.accentHex.caseInsensitiveCompare(c) == .orderedSame } }
            ?? next(for: profiles.count)
    }
}

// MARK: - Profile file (~/.config/usage-bar/profiles.json)

enum ProfileFile {
    static let dir = NSHomeDirectory() + "/.config/usage-bar"
    static let path = dir + "/profiles.json"
    static let legacyPath = NSHomeDirectory() + "/.config/claude-usage/profiles.json"

    /// nil when no file exists yet (first run).
    static func load() -> [Profile]? {
        for p in [path, legacyPath] {
            guard let data = FileManager.default.contents(atPath: p) else { continue }
            if let list = try? JSONDecoder().decode([Profile].self, from: data) { return list }
            Log.write("profiles: could not parse \(p)")
        }
        return nil
    }

    static func save(_ profiles: [Profile]) {
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(profiles).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            Log.write("profiles: save failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Login detection

enum Detect {
    /// Scan the home directory for Claude Code config dirs with a Keychain login
    /// and Codex homes with an auth.json. Names are guesses; users rename them.
    static func scan() -> [Profile] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var found: [Profile] = []
        var idx = 0
        func add(_ name: String, _ path: String, _ provider: Provider) {
            found.append(Profile(name: name, path: path, accentHex: Palette.next(for: idx), provider: provider))
            idx += 1
        }

        var claudeDirs: [String] = []
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty { claudeDirs.append(env) }
        let entries = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        for e in entries.sorted() where e.hasPrefix(".claude") {
            var isDir: ObjCBool = false
            let full = home + "/" + e
            if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue { claudeDirs.append(full) }
        }
        for dir in claudeDirs where hasClaudeLogin(dir) {
            let abbrev = (dir as NSString).abbreviatingWithTildeInPath
            let base = (dir as NSString).lastPathComponent
            let suffix = base.hasPrefix(".claude") ? String(base.dropFirst(".claude".count)) : base
            let label = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
            let name = label.isEmpty ? "Claude" : "Claude · \(label)"
            if !found.contains(where: { $0.provider == .claude && $0.path == abbrev }) { add(name, abbrev, .claude) }
        }

        var codexDirs = [home + "/.codex"]
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty { codexDirs.insert(env, at: 0) }
        for dir in codexDirs where fm.fileExists(atPath: dir + "/auth.json") {
            let abbrev = (dir as NSString).abbreviatingWithTildeInPath
            if !found.contains(where: { $0.provider == .codex && $0.path == abbrev }) { add("Codex", abbrev, .codex) }
        }
        return found
    }

    static func hasClaudeLogin(_ dir: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir + "/.credentials.json") || fm.fileExists(atPath: dir + "/token") { return true }
        let service = CredentialStore.keychainService(for: dir)
        return ((try? CredentialStore.readKeychain(service: service)) ?? nil) != nil
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

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded()), g = Int((ns.greenComponent * 255).rounded()), b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
