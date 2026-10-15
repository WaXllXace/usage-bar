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
    let profiles: [Profile]
    let demo: Bool

    @Published private(set) var states: [String: ProfileState] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var statusImage: NSImage = MenuBarLabel.placeholder()

    // Settings (persisted)
    @Published var refreshMinutes: Int { didSet { save(); restartTimer() } }
    @Published var enabled: Set<String> { didSet { save(); redraw() } }
    @Published var menuBarMode: MenuBarMode { didSet { save(); redraw() } }
    @Published var autoRefreshTokens: Bool { didSet { save() } }

    private var timerTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init(profiles: [Profile] = Profile.load(), demo: Bool = false) {
        self.profiles = profiles
        self.demo = demo
        refreshMinutes = max(1, defaults.object(forKey: "refreshMinutes") as? Int ?? 5)
        let savedEnabled = defaults.stringArray(forKey: "enabledProfiles")
        enabled = Set(savedEnabled ?? profiles.map(\.id))
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .rings
        autoRefreshTokens = defaults.object(forKey: "autoRefreshTokens") as? Bool ?? true
        for p in profiles { states[p.id] = .idle }
        redraw()
    }

    var enabledProfiles: [Profile] { profiles.filter { enabled.contains($0.id) } }

    func state(_ p: Profile) -> ProfileState { states[p.id] ?? .idle }

    private func save() {
        defaults.set(refreshMinutes, forKey: "refreshMinutes")
        defaults.set(Array(enabled), forKey: "enabledProfiles")
        defaults.set(menuBarMode.rawValue, forKey: "menuBarMode")
        defaults.set(autoRefreshTokens, forKey: "autoRefreshTokens")
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
        let last = state(p).snapshot
        states[p.id] = .loading(last: last)
        redraw()
        let allow = autoRefreshTokens
        do {
            let snap = try await UsageClient.fetch(profile: p, allowRefresh: allow)
            states[p.id] = .ok(snap)
        } catch {
            Log.write("fetch[\(p.id)] failed: \(error.localizedDescription)")
            states[p.id] = .error(error.localizedDescription, last: last)
        }
        redraw()
    }

    func toggle(_ p: Profile) {
        if enabled.contains(p.id) { enabled.remove(p.id) } else { enabled.insert(p.id) }
        if enabled.contains(p.id), state(p).snapshot == nil { Task { await refresh(p) } }
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

    private func loadDemo() {
        let now = Date()
        for (i, p) in profiles.enumerated() {
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
