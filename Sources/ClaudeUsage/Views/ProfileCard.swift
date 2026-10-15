import SwiftUI

struct ProfileCard: View {
    let profile: Profile
    @EnvironmentObject private var store: Store

    private var state: ProfileState { store.state(profile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let snap = state.snapshot {
                content(snap)
                if let err = state.errorText { errorRow(err, stale: true) }
            } else if let err = state.errorText {
                errorRow(err, stale: false)
            } else {
                loadingRows
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [profile.accent.opacity(0.55), profile.accent.opacity(0.12)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1)
                )
                .shadow(color: profile.accent.opacity(0.10), radius: 10, y: 4)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(
                    LinearGradient(colors: [profile.accent, profile.accent.opacity(0.65)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(profile.initial)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .shadow(color: profile.accent.opacity(0.4), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.system(size: 14, weight: .semibold))
                    badge(profile.provider.title, tint: .secondary)
                    if let plan = Fmt.plan(state.snapshot?.plan) {
                        badge(plan, tint: profile.accent)
                    }
                }
                HStack(spacing: 4) {
                    Text(profile.displayDir)
                    if let acct = state.snapshot?.account {
                        Text("·")
                        Text(acct).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
            Spacer()
            if state.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await store.refresh(profile) } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh \(profile.name)")
            }
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: Body

    private func content(_ snap: Snapshot) -> some View {
        HStack(alignment: .center, spacing: 16) {
            if let s = snap.session {
                VStack(spacing: 6) {
                    RingGauge(percent: s.percent, accent: profile.accent, caption: snap.ringCaption)
                    if let r = s.resetsAt {
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            VStack(spacing: 0) {
                                Text(Fmt.countdown(to: r, now: ctx.date))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text(Fmt.clock(r, now: ctx.date))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if s.isLimited {
                        Text(s.status ?? "limited")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                if snap.weekly.isEmpty && snap.session == nil {
                    Text("No active limits").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(snap.weekly) { b in
                    LevelBar(bucket: b, accent: profile.accent)
                }
                if let extra = snap.extra {
                    HStack(spacing: 4) {
                        Image(systemName: "creditcard").font(.system(size: 9))
                        Text(extra)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var loadingRows: some View {
        HStack(spacing: 16) {
            Circle().strokeBorder(profile.accent.opacity(0.12), lineWidth: 10).frame(width: 96, height: 96)
                .overlay(ProgressView().controlSize(.small))
            VStack(alignment: .leading, spacing: 12) {
                Shimmer(height: 10, width: 120)
                Shimmer(height: 7)
                Shimmer(height: 10, width: 90)
                Shimmer(height: 7)
            }
        }
    }

    private func errorRow(_ msg: String, stale: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill")
                .foregroundStyle(stale ? Color.orange : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                if stale {
                    Text("Showing last known values").font(.system(size: 11, weight: .semibold))
                }
                Text(msg).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background((stale ? Color.orange : Color.red).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
