import SwiftUI

/// Animated circular gauge with the percentage in the middle.
struct RingGauge: View {
    var percent: Double
    var accent: Color
    var size: CGFloat = 96
    var lineWidth: CGFloat = 10
    var caption: String? = nil

    @State private var animated: Double = 0

    private var color: Color { Severity.color(percent) }
    private var hot: Bool { percent >= 90 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.14), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.001, min(1, animated / 100)))
                .stroke(
                    AngularGradient(colors: [color.opacity(0.75), color], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * animated / 100)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(hot ? 0.6 : 0.25), radius: hot ? 8 : 3)
            VStack(spacing: 0) {
                (Text("\(Int(percent.rounded()))")
                    .font(.system(size: size * 0.30, weight: .bold, design: .rounded))
                 + Text("%")
                    .font(.system(size: size * 0.15, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let caption {
                    Text(caption)
                        .font(.system(size: size * 0.11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.15)) { animated = percent } }
        .onChange(of: percent) { _, new in withAnimation(.spring(duration: 0.9, bounce: 0.15)) { animated = new } }
        .modifier(PulseIfHot(active: hot))
    }
}

/// Subtle breathing scale when the gauge is near its limit.
struct PulseIfHot: ViewModifier {
    var active: Bool
    @State private var up = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(active && up ? 1.03 : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: up)
            .onAppear { up = active }
            .onChange(of: active) { _, a in up = a }
    }
}

/// Horizontal capsule bar with label, percent and reset info.
struct LevelBar: View {
    var bucket: Bucket
    var accent: Color

    @State private var animated: Double = 0
    private var color: Color { Severity.color(bucket.percent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if bucket.isLimited {
                    Text(bucket.status ?? "")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                }
                Text("\(Int(bucket.percent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(accent.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * min(1, animated / 100)))
                        .shadow(color: color.opacity(0.35), radius: 3, y: 1)
                }
            }
            .frame(height: 7)
            if let r = bucket.resetsAt {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text("\(Fmt.countdown(to: r, now: ctx.date)) · \(Fmt.clock(r, now: ctx.date))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.1)) { animated = bucket.percent } }
        .onChange(of: bucket.percent) { _, new in withAnimation(.spring(duration: 0.9, bounce: 0.1)) { animated = new } }
    }
}

/// Shimmering placeholder block used while a profile is loading for the first time.
struct Shimmer: View {
    var height: CGFloat
    var width: CGFloat? = nil
    @State private var phase: CGFloat = -1
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.07))
            .frame(width: width, height: height)
            .overlay(
                LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .offset(x: phase * 200)
                    .mask(RoundedRectangle(cornerRadius: 6))
            )
            .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.5 } }
    }
}
