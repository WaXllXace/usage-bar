import SwiftUI
import AppKit

/// "Manage Profiles" window: list on the left, editor on the right.
struct ProfilesWindow: View {
    @EnvironmentObject private var store: Store
    @State private var selection: String?
    @State private var detectMessage: String?

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 230, idealWidth: 250, maxWidth: 300)
            editor.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear { if selection == nil { selection = store.profiles.first?.id } }
        .onChange(of: store.profiles.map(\.id)) { _, ids in
            if let s = selection, !ids.contains(s) { selection = ids.first }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.profiles) { p in
                    HStack(spacing: 8) {
                        Circle().fill(p.accent).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 13, weight: .medium))
                            Text("\(p.provider.title) · \(p.displayDir)")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !p.enabled {
                            Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(p.id)
                }
                .onMove { from, to in store.move(from: from, to: to) }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 6) {
                Menu {
                    Button("Claude Code profile") { selection = store.add(provider: .claude).id }
                    Button("Codex CLI profile") { selection = store.add(provider: .codex).id }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                Button { if let s = selection { store.remove(s) } } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).disabled(selection == nil)
                Spacer()
                Button {
                    let n = store.detectNew()
                    detectMessage = n == 0 ? "No new logins found" : "Added \(n) login\(n == 1 ? "" : "s")"
                    Task { try? await Task.sleep(nanoseconds: 3_000_000_000); detectMessage = nil }
                } label: { Label("Detect logins", systemImage: "sparkle.magnifyingglass") }
                .buttonStyle(.borderless).font(.system(size: 11))
            }
            .padding(8)
            if let m = detectMessage {
                Text(m).font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 6)
            }
        }
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if let id = selection, let b = store.binding(for: id) {
            ProfileEditor(profile: b)
                .environmentObject(store)
                .id(id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 36)).foregroundStyle(.tertiary)
                Text(store.profiles.isEmpty ? "No profiles yet" : "Select a profile")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if store.profiles.isEmpty {
                    Text("Use “Detect logins” or + to add one.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProfileEditor: View {
    @Binding var profile: Profile
    @EnvironmentObject private var store: Store

    private var state: ProfileState { store.state(profile) }
    private var colorBinding: Binding<Color> {
        Binding(get: { profile.accent }, set: { profile.accentHex = $0.hexString })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                Picker("Provider", selection: $profile.provider) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: profile.provider) { old, new in
                    if profile.path == old.defaultDir || profile.path.isEmpty { profile.path = new.defaultDir }
                }
                HStack {
                    TextField(profile.provider == .claude ? "Config dir" : "Codex home", text: $profile.path)
                        .font(.system(.body, design: .monospaced))
                    Button("Choose…") { chooseFolder() }
                }
                Text(profile.provider.hint).font(.system(size: 11)).foregroundStyle(.secondary)
                ColorPicker("Colour", selection: colorBinding, supportsOpacity: false)
            }
            Section {
                Toggle("Show in menu bar", isOn: $profile.enabled)
                if profile.provider == .claude {
                    Toggle("Auto-refresh expired token", isOn: $profile.autoRefresh)
                    Text("When the access token has expired, refresh it with the stored refresh token and write it back to the Keychain (what the Claude CLI does itself while running). Off: the card asks you to run `claude` instead.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("Status") {
                statusRow
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            if state.isLoading {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            } else if let e = state.errorText {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(e).foregroundStyle(.secondary).textSelection(.enabled)
            } else if let s = state.snapshot {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                let plan = Fmt.plan(s.plan).map { " · \($0)" } ?? ""
                let acct = s.account.map { " · \($0)" } ?? ""
                Text("Connected\(plan)\(acct) · \(s.buckets.count) limit\(s.buckets.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                Text(profile.enabled ? "Not checked yet" : "Hidden").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check now") { Task { await store.refresh(profile) } }
                .disabled(state.isLoading)
        }
        .font(.system(size: 12))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: profile.configDir).deletingLastPathComponent()
        panel.message = profile.provider == .claude ? "Choose a Claude Code config directory" : "Choose the Codex home directory"
        if panel.runModal() == .OK, let url = panel.url {
            profile.path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
