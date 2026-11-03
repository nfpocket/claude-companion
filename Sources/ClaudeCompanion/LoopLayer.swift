import AppKit
import SwiftUI

/// Looping indicators drawn by Core Animation: the render server runs them, so a
/// spinning or pulsing status costs the app next to no CPU (SwiftUI-driven frames did).
struct LoopLayer: NSViewRepresentable {
    enum Kind: Equatable {
        case spinner(lineWidth: CGFloat)
        case pulse
        case breathe
    }

    var kind: Kind
    var color: Color

    func makeNSView(context: Context) -> LoopLayerView { LoopLayerView(kind: kind, color: NSColor(color)) }

    func updateNSView(_ view: LoopLayerView, context: Context) {
        view.update(kind: kind, color: NSColor(color))
    }
}

final class LoopLayerView: NSView {
    private let shape = CAShapeLayer()
    private var kind: LoopLayer.Kind
    private var color: NSColor

    init(kind: LoopLayer.Kind, color: NSColor) {
        self.kind = kind
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = nil
        shape.lineCap = .round
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(kind: LoopLayer.Kind, color: NSColor) {
        guard kind != self.kind || color != self.color else { return }
        self.kind = kind
        self.color = color
        restyle()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        switch kind {
        case .spinner(let w):
            shape.path = CGPath(ellipseIn: bounds.insetBy(dx: w / 2, dy: w / 2), transform: nil)
            shape.lineWidth = w
            shape.strokeStart = 0
            shape.strokeEnd = 0.28
        case .pulse:
            shape.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
            shape.lineWidth = 2
        case .breathe:
            shape.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
            shape.lineWidth = 1
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        shape.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { restyle() }
    }

    private func restyle() {
        shape.strokeColor = color.cgColor
        shape.removeAllAnimations()
        switch kind {
        case .spinner:
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -2 * Double.pi // clockwise
            a.duration = 1.1
            a.repeatCount = .infinity
            shape.add(a, forKey: "loop")
        case .pulse:
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 1.45
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [scale, fade]
            g.duration = 1.8
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shape.add(g, forKey: "loop")
        case .breathe:
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 1.05
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.4
            fade.toValue = 1
            let g = CAAnimationGroup()
            g.animations = [scale, fade]
            g.duration = 2.25
            g.autoreverses = true
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(g, forKey: "loop")
        }
    }
}

/// Blinks now and then without redrawing anything in between.
struct BlinkClock: ViewModifier {
    @Binding var blink: Bool
    var active: Bool

    func body(content: Content) -> some View {
        content.task(id: active) {
            guard active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 3.5...6.5)))
                blink = true
                try? await Task.sleep(for: .milliseconds(130))
                blink = false
            }
        }
    }
}
