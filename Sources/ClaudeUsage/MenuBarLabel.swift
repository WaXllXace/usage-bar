import AppKit

/// Draws the status-item image: one mini ring per profile (arc = usage, tinted
/// by the profile accent, red when hot) followed by the percentage.
enum MenuBarLabel {
    struct Entry {
        var accent: NSColor
        var percent: Double?
        var error: Bool
        var loading: Bool
    }

    static let height: CGFloat = 18
    static let ring: CGFloat = 13
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    static func placeholder() -> NSImage { render([], mode: .rings) }

    static func render(_ entries: [Entry], mode: MenuBarMode) -> NSImage {
        let items = entries.isEmpty ? [Entry(accent: .secondaryLabelColor, percent: nil, error: false, loading: true)] : entries
        let labels: [String] = items.map { e in
            if mode == .compact { return "" }
            if e.error { return "!" }
            guard let p = e.percent else { return "…" }
            return "\(Int(p.rounded()))%"
        }
        let textWidths = labels.map { $0.isEmpty ? 0 : ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
        let gapRingText: CGFloat = 3, gapItems: CGFloat = 7
        var width: CGFloat = 0
        for (i, w) in textWidths.enumerated() {
            if mode != .text { width += ring }
            if w > 0 { width += (mode != .text ? gapRingText : 0) + w }
            if i < textWidths.count - 1 { width += gapItems }
        }
        width = max(width, ring)

        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            let textColor = NSColor.labelColor
            for (i, e) in items.enumerated() {
                if mode != .text {
                    drawRing(at: NSPoint(x: x, y: (height - ring) / 2), entry: e)
                    x += ring
                }
                let label = labels[i]
                if !label.isEmpty {
                    if mode != .text { x += gapRingText }
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: e.error ? NSColor.systemRed : (mode == .text ? e.accent : textColor),
                    ]
                    let size = (label as NSString).size(withAttributes: attrs)
                    (label as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2 + 0.5), withAttributes: attrs)
                    x += textWidths[i]
                }
                x += gapItems
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func drawRing(at origin: NSPoint, entry: Entry) {
        let lineWidth: CGFloat = 2.6
        let rect = NSRect(x: origin.x + lineWidth / 2, y: origin.y + lineWidth / 2,
                          width: ring - lineWidth, height: ring - lineWidth)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2

        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        entry.accent.withAlphaComponent(0.28).setStroke()
        track.stroke()

        guard let pct = entry.percent, !entry.error else {
            if entry.error {
                let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
                NSColor.systemRed.setFill(); dot.fill()
            }
            return
        }
        let frac = max(0, min(1, pct / 100))
        guard frac > 0.005 else { return }
        let arc = NSBezierPath()
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        // Clockwise from 12 o'clock; AppKit angles are counter-clockwise from 3 o'clock.
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                      endAngle: 90 - 360 * frac, clockwise: true)
        (pct >= 80 ? NSColor.systemRed : entry.accent).setStroke()
        arc.stroke()
    }
}
