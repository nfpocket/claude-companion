import AppKit
import SwiftUI

/// How the graph canvas is zoomed and panned. `zoom` nil follows the layout (as big as fits,
/// but readable); a number is the user's own zoom, with `pan` the content's top-left corner.
struct CanvasView: Equatable {
    var zoom: CGFloat?
    var pan: CGPoint = .zero

    static let zooms: ClosedRange<CGFloat> = 0.3...2

    /// Where the content's top-left corner goes: centered in a direction where it fits, else
    /// kept so that no edge comes further in than the margin.
    static func clamp(_ pan: CGPoint, content: CGSize, stage: CGSize, margin: CGFloat) -> CGPoint {
        func axis(_ p: CGFloat, _ c: CGFloat, _ s: CGFloat) -> CGFloat {
            if c <= s - 2 * margin { return (s - c) / 2 }
            return min(margin, max(s - margin - c, p))
        }
        return CGPoint(x: axis(pan.x, content.width, stage.width), y: axis(pan.y, content.height, stage.height))
    }

    /// The pan that keeps the content point under `anchor` in place while the scale changes.
    static func zoomed(_ pan: CGPoint, from old: CGFloat, to new: CGFloat, at anchor: CGPoint) -> CGPoint {
        let k = new / old
        return CGPoint(x: anchor.x - (anchor.x - pan.x) * k, y: anchor.y - (anchor.y - pan.y) * k)
    }
}

/// What the menu and keyboard ask of the canvas.
enum CanvasCommand: Equatable { case zoomIn, zoomOut, fit, reset }

/// A stage you can pan (scroll, or two fingers on the trackpad) and zoom (pinch, ⌘-scroll,
/// ⌘+ / ⌘−, or the buttons in its corner). It starts at the layout's own scale, centered, and
/// goes back to that with "fit to window".
struct ZoomCanvas<Content: View>: View {
    @EnvironmentObject var model: AppModel
    /// The content's own size and the scales the layout suggests.
    var size: CGSize
    var autoScale: CGFloat
    var fitScale: CGFloat
    var stage: CGSize
    @ViewBuilder var content: () -> Content
    @StateObject private var events = CanvasEvents()

    private var margin: CGFloat { GraphLayout.margin }

    var body: some View {
        let view = model.canvas
        let scale = view.zoom ?? autoScale
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        let start = CGPoint(x: margin, y: margin)
        let pan = CanvasView.clamp(view.zoom == nil ? start : view.pan, content: scaled, stage: stage, margin: margin)
        ZStack(alignment: .topLeading) {
            content()
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: pan.x, y: pan.y)
        }
        .frame(width: stage.width, height: stage.height, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Color.clear
                .onAppear { events.frame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in events.frame = f }
        })
        .overlay(alignment: .bottomTrailing) {
            ZoomControls(percent: Int((scale * 100).rounded()), auto: view.zoom == nil,
                         zoomOut: { zoom(by: 1 / 1.25, at: nil) }, zoomIn: { zoom(by: 1.25, at: nil) },
                         fit: { fit() })
                .padding(12)
        }
        // The monitor's handler is rebuilt when the geometry changes, so it never works with old sizes.
        .onChange(of: [size.width, size.height, stage.width, stage.height, autoScale, fitScale], initial: true) { _, _ in
            events.handler = { e in handle(e) }
        }
        .onAppear { events.install() }
        .onDisappear {
            events.remove()
            events.handler = nil // it holds this view, which holds `events`
        }
        .onChange(of: model.canvasCommand?.id) { _, _ in
            guard let c = model.canvasCommand?.command else { return }
            switch c {
            case .zoomIn: zoom(by: 1.25, at: nil)
            case .zoomOut: zoom(by: 1 / 1.25, at: nil)
            case .fit: fit()
            case .reset: model.canvas = CanvasView()
            }
        }
    }

    private var current: (scale: CGFloat, pan: CGPoint) {
        let v = model.canvas
        let scale = v.zoom ?? autoScale
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        return (scale, CanvasView.clamp(v.zoom == nil ? CGPoint(x: margin, y: margin) : v.pan, content: scaled, stage: stage, margin: margin))
    }

    /// Zooms by `factor` around `anchor` (in the canvas; nil: its middle).
    private func zoom(by factor: CGFloat, at anchor: CGPoint?) {
        let (s0, p0) = current
        let s1 = min(CanvasView.zooms.upperBound, max(CanvasView.zooms.lowerBound, s0 * factor))
        guard abs(s1 - s0) > 0.0001 else { return }
        let a = anchor ?? CGPoint(x: stage.width / 2, y: stage.height / 2)
        let p1 = CanvasView.zoomed(p0, from: s0, to: s1, at: a)
        let scaled = CGSize(width: size.width * s1, height: size.height * s1)
        model.canvas = CanvasView(zoom: s1, pan: CanvasView.clamp(p1, content: scaled, stage: stage, margin: margin))
    }

    /// Everything in view, however small that makes it.
    private func fit() {
        let s = max(CanvasView.zooms.lowerBound, fitScale)
        let scaled = CGSize(width: size.width * s, height: size.height * s)
        model.canvas = CanvasView(zoom: s, pan: CanvasView.clamp(.zero, content: scaled, stage: stage, margin: margin))
    }

    private func pan(by d: CGSize) {
        let (s, p0) = current
        let scaled = CGSize(width: size.width * s, height: size.height * s)
        let p1 = CanvasView.clamp(CGPoint(x: p0.x + d.width, y: p0.y + d.height), content: scaled, stage: stage, margin: margin)
        guard p1 != p0 else { return }
        model.canvas = CanvasView(zoom: s, pan: p1)
    }

    /// Scroll and pinch events over the canvas. Returns true when it used the event.
    private func handle(_ e: NSEvent) -> Bool {
        // Only the companion's own window (not the pill, a popover or a sheet), key or not.
        guard let window = e.window, window.identifier?.rawValue == AppDelegate.mainWindowId,
              window.attachedSheet == nil, let host = window.contentView, !model.canvasBlocked else { return false }
        let p = host.convert(e.locationInWindow, from: nil)
        let point = CGPoint(x: p.x, y: host.isFlipped ? p.y : host.bounds.height - p.y)
        let f = events.frame
        guard f.contains(point) else { return false }
        let local = CGPoint(x: point.x - f.minX, y: point.y - f.minY)
        switch e.type {
        case .magnify:
            zoom(by: 1 + e.magnification, at: local)
            return true
        case .scrollWheel:
            var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
            if !e.hasPreciseScrollingDeltas { dx *= 8; dy *= 8 }
            if e.modifierFlags.contains(.command) {
                zoom(by: exp(dy * 0.01), at: local)
            } else {
                pan(by: CGSize(width: dx, height: dy))
            }
            return true
        default:
            return false
        }
    }
}

/// Holds the event monitor and where the canvas is in its window.
final class CanvasEvents: ObservableObject {
    var frame: CGRect = .zero
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?

    func install() {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
            let used = MainActor.assumeIsolated { self?.handler?(e) ?? false }
            return used ? nil : e
        }
    }

    func remove() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit { remove() }
}

/// − 100 % + and "fit", in the canvas's corner.
struct ZoomControls: View {
    var percent: Int
    var auto: Bool
    var zoomOut: () -> Void
    var zoomIn: () -> Void
    var fit: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("minus", ui("Zoom out (⌘−)", "Verkleinern (⌘−)"), zoomOut)
            Text("\(percent)%")
                .font(Theme.mono(11))
                .foregroundColor(auto ? Theme.faint : Theme.text)
                .frame(width: 44)
            button("plus", ui("Zoom in (⌘+)", "Vergrößern (⌘+)"), zoomIn)
            Rectangle().fill(Theme.border).frame(width: 1, height: 16)
            button("arrow.down.right.and.arrow.up.left", ui("Fit everything in the window (⌥⌘0)", "Alles ins Fenster einpassen (⌥⌘0)"), fit)
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        .help(ui("Scroll to move around, pinch or ⌘-scroll to zoom", "Scrollen zum Verschieben, Zwicken oder ⌘-Scrollen zum Zoomen"))
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.muted)
        .help(help)
    }
}
