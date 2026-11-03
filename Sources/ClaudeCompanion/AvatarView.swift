import SwiftUI

/// False while the surface is hidden or covered, so its animations stop costing CPU.
private struct AnimatingKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var animating: Bool {
        get { self[AnimatingKey.self] }
        set { self[AnimatingKey.self] = newValue }
    }
}

/// The little clay pebble with eyes, plus the rings that show what it is doing.
struct AvatarView: View {
    var mode: AvatarMode
    var size: CGFloat = 140
    var level: () -> Float = { 0 }
    @Environment(\.animating) private var animating
    @State private var blink = false

    var body: some View {
        let s = size / 140
        Group {
            if mode == .idle {
                // Idle is the normal state: Core Animation breathes, a timer blinks, nothing else redraws.
                ZStack {
                    LoopLayer(kind: .breathe, color: Theme.accent.opacity(0.55))
                        .allowsHitTesting(false)
                    innerDisc(s)
                    Pebble(mode: .idle, t: blink ? 0 : 1, scale: s)
                    spark(s, opacity: 1)
                }
                .modifier(BlinkClock(blink: $blink, active: animating))
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    ZStack {
                        rings(t: t, s: s)
                        innerDisc(s)
                        Pebble(mode: mode, t: t, level: CGFloat(mode == .speaking ? level() : 0), scale: s)
                        spark(s, opacity: mode == .thinking ? 0.5 + 0.5 * abs(sin(t * 3)) : 1)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibility))
    }

    private func innerDisc(_ s: CGFloat) -> some View {
        Circle()
            .fill(innerFill)
            .overlay(Circle().stroke(innerStroke, lineWidth: 1))
            .frame(width: 112 * s, height: 112 * s)
    }

    private func spark(_ s: CGFloat, opacity: Double) -> some View {
        Spark()
            .fill(Theme.accentLight)
            .frame(width: 18 * s, height: 18 * s)
            .offset(x: 37 * s, y: -41 * s)
            .opacity(opacity)
    }

    private var accessibility: String {
        switch mode {
        case .idle: return "Claude, watching your sessions"
        case .listening: return "Claude, listening"
        case .thinking: return "Claude, thinking"
        case .speaking: return "Claude, speaking"
        }
    }

    private var innerFill: Color {
        switch mode {
        case .listening: return Color(hex: 0x1A1D24)
        case .speaking: return Color(hex: 0x1E1A19)
        default: return Color(hex: 0x1A1B1F)
        }
    }

    private var innerStroke: Color {
        switch mode {
        case .listening: return Color(hex: 0x36507A)
        case .speaking: return Color(hex: 0x4A3029)
        default: return Theme.line
        }
    }

    @ViewBuilder
    private func rings(t: Double, s: CGFloat) -> some View {
        switch mode {
        case .idle:
            EmptyView()
        case .listening:
            ForEach(0..<3, id: \.self) { k in
                let p = (t / 2.4 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(Color(hex: 0x8DBBFF).opacity(0.7 * (1 - p)), lineWidth: 2)
                    .frame(width: 128 * s, height: 128 * s)
                    .scaleEffect(0.92 + 0.8 * p)
            }
        case .thinking:
            let a = t * 2 * .pi / 1.6
            Circle().stroke(Theme.line, lineWidth: 1).frame(width: 128 * s, height: 128 * s)
            Circle()
                .fill(Theme.accentLight)
                .frame(width: 8 * s, height: 8 * s)
                .offset(x: 64 * s * cos(a), y: 64 * s * sin(a))
        case .speaking:
            ForEach(0..<2, id: \.self) { k in
                let p = (t / 2.2 + Double(k) / 2).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(Theme.accent.opacity(0.6 * (1 - p)), lineWidth: 2)
                    .frame(width: 124 * s, height: 124 * s)
                    .scaleEffect(0.95 + 0.6 * p)
            }
        }
    }
}

struct Pebble: View {
    var mode: AvatarMode
    var t: Double
    var level: CGFloat = 0
    var scale: CGFloat = 1

    var body: some View {
        let s = scale
        let shape = UnevenRoundedRectangle(topLeadingRadius: 28 * s, bottomLeadingRadius: 24 * s,
                                           bottomTrailingRadius: 24 * s, topTrailingRadius: 28 * s)
        let blinking = t.truncatingRemainder(dividingBy: 4.7) < 0.13
        let eye = eyeSize
        let look = mode == .thinking ? 3 * s * CGFloat(sin(t * 1.3)) : 0
        ZStack {
            shape.fill(Theme.accent)
            Rectangle()
                .fill(Color.black.opacity(0.14))
                .frame(height: 7 * s)
                .frame(maxHeight: .infinity, alignment: .bottom)
            VStack(spacing: 7 * s) {
                HStack(spacing: (mode == .listening ? 18 : 20) * s) {
                    Capsule().fill(Theme.eye).frame(width: eye.width * s, height: (blinking ? 2 : eye.height) * s)
                    Capsule().fill(Theme.eye).frame(width: eye.width * s, height: (blinking ? 2 : eye.height) * s)
                }
                .frame(height: 21 * s)
                .offset(x: look)
                if mode == .speaking {
                    Capsule()
                        .fill(Theme.eye)
                        .frame(width: 18 * s, height: max(2, 9 * level) * s)
                        .frame(height: 9 * s)
                }
            }
            .offset(y: (mode == .speaking ? -1 : -6) * s)
        }
        .clipShape(shape)
        .frame(width: 78 * s, height: 70 * s)
    }

    private var eyeSize: CGSize {
        switch mode {
        case .listening: return CGSize(width: 12, height: 21)
        case .speaking: return CGSize(width: 9, height: 15)
        default: return CGSize(width: 9, height: 17)
        }
    }
}

/// A four-pointed spark.
struct Spark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let w = r.width / 2, h = r.height / 2
        let k: CGFloat = 0.18
        p.move(to: CGPoint(x: c.x, y: c.y - h))
        p.addLine(to: CGPoint(x: c.x + w * k, y: c.y - h * k))
        p.addLine(to: CGPoint(x: c.x + w, y: c.y))
        p.addLine(to: CGPoint(x: c.x + w * k, y: c.y + h * k))
        p.addLine(to: CGPoint(x: c.x, y: c.y + h))
        p.addLine(to: CGPoint(x: c.x - w * k, y: c.y + h * k))
        p.addLine(to: CGPoint(x: c.x - w, y: c.y))
        p.addLine(to: CGPoint(x: c.x - w * k, y: c.y - h * k))
        p.closeSubpath()
        return p
    }
}

/// The pebble alone, for the pill and small places.
struct MiniAvatar: View {
    var mode: AvatarMode
    var height: CGFloat = 18
    var level: () -> Float = { 0 }
    @Environment(\.animating) private var animating
    @State private var blink = false

    var body: some View {
        Group {
            if mode == .idle {
                Pebble(mode: .idle, t: blink ? 0 : 1, scale: height / 70)
                    .modifier(BlinkClock(blink: $blink, active: animating))
            } else {
                TimelineView(.animation(minimumInterval: 1 / 24, paused: !animating)) { ctx in
                    Pebble(mode: mode, t: ctx.date.timeIntervalSinceReferenceDate,
                           level: CGFloat(mode == .speaking ? level() : 0), scale: height / 70)
                }
            }
        }
        .frame(width: height * 78 / 70, height: height)
    }
}

// MARK: - Status glyphs

struct Spinner: View {
    var color: Color
    var size: CGFloat
    var lineWidth: CGFloat = 2.4

    var body: some View {
        LoopLayer(kind: .spinner(lineWidth: lineWidth), color: color)
            .allowsHitTesting(false)
            .frame(width: size, height: size)
    }
}

/// The bare icon for a status, as in the header chips and the pill.
struct StatusGlyph: View {
    var status: SessionStatus
    var size: CGFloat = 13

    var body: some View {
        Group {
            if status == .working {
                Spinner(color: status.color, size: size * 0.95, lineWidth: max(1.6, size * 0.2))
            } else {
                Image(systemName: status.symbol)
                    .font(.system(size: size * 0.82, weight: .heavy))
                    .foregroundColor(status.color)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Status icon on a tinted disc; needs-you pulses.
struct StatusBadge: View {
    var status: SessionStatus
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(status.color.opacity(0.15))
            StatusGlyph(status: status, size: size * 0.5)
        }
        .frame(width: size, height: size)
        .overlay {
            if status == .needs {
                LoopLayer(kind: .pulse, color: status.color).allowsHitTesting(false)
            }
        }
    }
}
