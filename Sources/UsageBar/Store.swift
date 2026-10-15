import SwiftUI
import Combine

enum MenuBarMode: String, CaseIterable, Identifiable {
    case rings = "Rings + %"
    case compact = "Rings only"
    case text = "Text only"
    var id: String { rawValue }
}

@MainActor
final class Store: ObservableObject {
    let demo: Bool

    @Published var profiles: [Profile] {
        didSet { if !demo { ProfileFile.save(profiles) }; reconcile(old: oldValue) }
    }
    @Published private(set) var states: [String: ProfileState] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var statusImage: NSImage = MenuBarLabel.placeholder()
    @Published private(set) var isFirstRun = false

    // Settings (persisted in UserDefaults)
    @Published var refreshMinutes: Int { didSet { save(); restartTimer() } }
    @Published var menuBarMode: MenuBarMode { didSet { save(); redraw() } }

    private var timerTask: Task<Void, Never>?
    private var pendingRefetch: [String: Task<Void, Never>] = [:]
    private let defaults = UserDefaults.standard

    init(demo: Bool = false) {
        self.demo = demo
        refreshMinutes = max(1, defaults.object(forKey: "refreshMinutes") as? Int ?? 5)
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .rings
        if demo {
            profiles = Self.demoProfiles
        } else if let saved = ProfileFile.load() {
            profiles = saved
        } else {
            let detected = Detect.scan()
            profiles = detected
            isFirstRun = true
            ProfileFile.save(detected)
            Log.write("first run: detected \(detected.count) login(s)")
        }
        for p in profiles { states[p.id] = .idle }
        redraw()
    }

    var enabledProfiles: [Profile] { profiles.filter(\.enabled) }

    func state(_ p: Profile) -> ProfileState { states[p.id] ?? .idle }

    private func save() {
        defaults.set(refreshMinutes, forKey: "refreshMinutes")
        defaults.set(menuBarMode.rawValue, forKey: "menuBarMode")
    }

    // MARK: Profile CRUD

    func binding(for id: String) -> Binding<Profile>? {
        guard profiles.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.profiles.first { $0.id == id } ?? Profile(name: "", path: "", accentHex: "#888888") },
            set: { new in if let i = self.profiles.firstIndex(where: { $0.id == id }) { self.profiles[i] = new } })
    }

    @discardableResult
    func add(provider: Provider = .claude) -> Profile {
        let p = Profile(name: provider.title, path: provider.defaultDir,
                        accentHex: Palette.unused(by: profiles), provider: provider)
        profiles.append(p)
        return p
    }

    func remove(_ id: String) {
        profiles.removeAll { $0.id == id }
    }

    func move(from: IndexSet, to: Int) {
        profiles.move(fromOffsets: from, toOffset: to)
    }

    func toggle(_ p: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i].enabled.toggle()
    }

    /// Scan for logins and append any not already tracked. Returns how many were added.
    @discardableResult
    func detectNew() -> Int {
        let found = Detect.scan()
        var added = 0
        for f in found where !profiles.contains(where: { $0.sameLogin(as: f) }) {
            var p = f
            p.accentHex = Palette.unused(by: profiles)
            profiles.append(p)
            added += 1
        }
        return added
    }

    /// Keep `states` in step with `profiles`; refetch profiles whose login changed.
    private func reconcile(old: [Profile]) {
        let ids = Set(profiles.map(\.id))
        for k in states.keys where !ids.contains(k) { states[k] = nil; pendingRefetch[k]?.cancel() }
        for p in profiles {
            let prev = old.first { $0.id == p.id }
            if states[p.id] == nil { states[p.id] = .idle }
            let loginChanged = prev.map { $0.configDir != p.configDir || $0.provider != p.provider } ?? true
            let justEnabled = p.enabled && !(prev?.enabled ?? false)
            if loginChanged || (justEnabled && state(p).snapshot == nil) {
                states[p.id] = .idle
                pendingRefetch[p.id]?.cancel()
                pendingRefetch[p.id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000)   // debounce typing
                    guard !Task.isCancelled, let self else { return }
                    if self.demo { self.loadDemo() } else { await self.refresh(p) }
                }
            }
        }
        redraw()
    }

    // MARK: Lifecycle

    func start() {
        if demo { loadDemo(); return }
        restartTimer()
    }

    private func restartTimer() {
        timerTask?.cancel()
        let interval = UInt64(refreshMinutes) * 60_000_000_000
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func refreshAll() async {
        if demo { loadDemo(); return }
        guard !isRefreshing else { return }
        isRefreshing = true
        await withTaskGroup(of: Void.self) { group in
            for p in enabledProfiles {
                group.addTask { await self.refresh(p) }
            }
        }
        lastRefresh = .now
        isRefreshing = false
        redraw()
    }

    func refresh(_ p: Profile) async {
        guard let current = profiles.first(where: { $0.id == p.id }) else { return }
        let last = state(current).snapshot
        states[current.id] = .loading(last: last)
        redraw()
        do {
            let snap = try await UsageClient.fetch(profile: current, allowRefresh: current.autoRefresh)
            states[current.id] = .ok(snap)
        } catch {
            Log.write("fetch[\(current.name)] failed: \(error.localizedDescription)")
            states[current.id] = .error(error.localizedDescription, last: last)
        }
        redraw()
    }

    // MARK: Menu bar image

    private func redraw() {
        let entries = enabledProfiles.map { p -> MenuBarLabel.Entry in
            let st = state(p)
            return MenuBarLabel.Entry(accent: NSColor(p.accent),
                                      percent: st.snapshot?.headline?.percent,
                                      error: st.errorText != nil,
                                      loading: st.isLoading && st.snapshot == nil)
        }
        statusImage = MenuBarLabel.render(entries, mode: menuBarMode)
    }

    // MARK: Demo data (for --demo / --render-preview)

    static let demoProfiles: [Profile] = [
        Profile(id: "demo-work", name: "Work", path: "~/.claude", accentHex: Palette.colors[0]),
        Profile(id: "demo-personal", name: "Personal", path: "~/.claude-personal", accentHex: Palette.colors[1]),
        Profile(id: "demo-codex", name: "Codex", path: "~/.codex", accentHex: Palette.colors[2], provider: .codex),
    ]

    private func loadDemo() {
        let now = Date()
        for (i, p) in profiles.enumerated() {
            if p.provider == .codex {
                states[p.id] = .ok(Snapshot(buckets: [
                    Bucket(key: "five_hour", label: "Weekly", percent: 59,
                           resetsAt: now.addingTimeInterval(444_808), status: nil),
                ], fetchedAt: now, plan: "pro", source: .api,
                   account: "engineer@example.com", extra: "credits: 62,500"))
                continue
            }
            let base = i == 0 ? 23.0 : 67.0
            let snap = Snapshot(buckets: [
                Bucket(key: "five_hour", label: Bucket.label(for: "five_hour"), percent: base,
                       resetsAt: now.addingTimeInterval(Double(i + 1) * 4_120), status: "allowed"),
                Bucket(key: "seven_day", label: Bucket.label(for: "seven_day"), percent: base * 0.6 + 8,
                       resetsAt: now.addingTimeInterval(86_400 * 2.3), status: "allowed"),
                Bucket(key: "weekly_scoped:Fable", label: "Weekly · Fable", percent: i == 0 ? 41 : 88,
                       resetsAt: now.addingTimeInterval(86_400 * 2.3), status: nil),
            ], fetchedAt: now, plan: i == 0 ? "team" : "max", source: .api)
            states[p.id] = .ok(snap)
        }
        lastRefresh = now
        redraw()
    }
}
