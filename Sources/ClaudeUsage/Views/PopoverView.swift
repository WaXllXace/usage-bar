import SwiftUI
import ServiceManagement

struct PopoverView: View {
    static let width: CGFloat = 372
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(spacing: 12) {
            titleBar
            if store.enabledProfiles.isEmpty {
                Text("All profiles hidden. Enable one in ⚙︎.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
            ForEach(store.enabledProfiles) { p in
                ProfileCard(profile: p)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.06), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
        .animation(.spring(duration: 0.4), value: store.enabledProfiles.map(\.id))
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: Profile.defaults.map(\.accent), startPoint: .leading, endPoint: .trailing))
            Text("Claude Usage").font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
            if let t = store.lastRefresh {
                TimelineView(.periodic(from: .now, by: 5)) { ctx in
                    Text(Fmt.ago(t, now: ctx.date))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Button { Task { await store.refreshAll() } } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 17))
                    .symbolEffect(.pulse, isActive: store.isRefreshing)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh all")
            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            Section("Profiles") {
                ForEach(store.profiles) { p in
                    Toggle(p.name, isOn: Binding(
                        get: { store.enabled.contains(p.id) },
                        set: { _ in store.toggle(p) }))
                }
            }
            Section("Menu bar") {
                Picker("Style", selection: $store.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.inline)
            }
            Section("Refresh every") {
                Picker("Interval", selection: $store.refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15], id: \.self) { m in Text("\(m) min").tag(m) }
                }
                .pickerStyle(.inline)
            }
            Section {
                Toggle("Auto-refresh expired tokens", isOn: $store.autoRefreshTokens)
                LaunchAtLoginToggle()
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(store.demo ? "demo data" : "data: Anthropic usage API")
                .font(.system(size: 10)).foregroundStyle(.quaternary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.top, 2)
    }
}

/// Login-item toggle backed by SMAppService (only meaningful from a .app bundle).
struct LaunchAtLoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { on },
            set: { v in
                do {
                    if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    on = SMAppService.mainApp.status == .enabled
                } catch {
                    NSLog("launch-at-login: \(error.localizedDescription)")
                    on = SMAppService.mainApp.status == .enabled
                }
            }))
        .disabled(!available)
    }
}
