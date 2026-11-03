import AppKit
import SwiftUI
import Combine

/// A borderless panel that sits in the notch, above the menu bar, on every Space.
final class PillPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var window: NSWindow!
    private var pill: PillPanel!
    private var pillHost: FirstClickHostingView<AnyView>!
    private var metrics = PillMetrics(hasNotch: false, notchWidth: 0, stripHeight: 34)
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var pillScheduled = false
    private var lastPillFrame: NSRect = .zero
    private var lastPillMetrics: PillMetrics?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        model.onOpenWindow = { [weak self] in self?.showWindow() }
        model.onUILanguageChange = { [weak self] in self?.buildMenu() }
        buildMenu()
        buildWindow()
        buildPill()
        model.start()

        model.objectWillChange
            .sink { [weak self] _ in self?.schedulePillUpdate() }
            .store(in: &cancellables)
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSApplication.didChangeScreenParametersNotification] {
            nc.publisher(for: name).sink { [weak self] _ in self?.schedulePillUpdate() }.store(in: &cancellables)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.schedulePillUpdate() }
            .store(in: &cancellables)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            // Returning nil swallows the event. (`self?.handleKey(e) ?? e` would hand every
            // swallowed key back to the window, which beeps because nothing handles Space.)
            guard let self else { return e }
            return self.handleKey(e)
        }
        // Holding Space in the window and then clicking away never delivers the key-up here.
        nc.publisher(for: NSWindow.didResignKeyNotification, object: window)
            .sink { [weak self] _ in self?.releaseSpace() }
            .store(in: &cancellables)

        // Debug aid: post "local.claude-companion.snapshot" and the app writes PNGs of its
        // windows to ~/Library/Caches/ClaudeCompanion/ (no Screen Recording permission needed).
        DistributedNotificationCenter.default().publisher(for: Notification.Name("local.claude-companion.snapshot"))
            .sink { [weak self] _ in self?.writeSnapshots() }
            .store(in: &cancellables)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("local.claude-companion.pill"))
            .sink { [weak self] _ in self?.model.pillExpanded.toggle() }
            .store(in: &cancellables)

        // Type a command instead of saying it:
        //   post "local.claude-companion.heard" with userInfo {"text": "what needs me"}
        DistributedNotificationCenter.default().publisher(for: Notification.Name("local.claude-companion.heard"))
            .sink { [weak self] n in
                if let text = n.userInfo?["text"] as? String { self?.model.act(onText: text) }
            }
            .store(in: &cancellables)

        showWindow()
        updatePill()
        if let dir = Demo.folder { captureDemo(to: dir) }
    }

    /// Demo mode: screenshots of the orbit window and the opened pill, then quit.
    private func captureDemo(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ view: NSView?, _ name: String) {
            guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
            write(window.contentView?.superview ?? window.contentView, "orbit.png")
            model.pillExpanded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                let size = PillView.size(model, metrics)
                pill.setFrame(NSRect(origin: pill.frame.origin, size: size), display: true)
                pillHost.layoutSubtreeIfNeeded()
                write(pillHost, "pill.png")
                NSApp.terminate(nil)
            }
        }
    }

    private func writeSnapshots() {
        let dir = Paths.ttsCache.deletingLastPathComponent()
        for (name, view) in [("main", window.contentView), ("pill", pill.contentView)] {
            guard let view, view.bounds.width > 0,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("snapshot-\(name).png"))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Claude Companion"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0x14 / 255, green: 0x15 / 255, blue: 0x18 / 255, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 980, height: 660)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: MainView().environmentObject(model))
        // The window's size is the user's: SwiftUI content (a long summary, a caption)
        // must not push it bigger than the screen.
        host.sizingOptions = []
        window.contentView = host
        window.center()
        if Demo.on { return }
        window.setFrameAutosaveName("CompanionMain")
        fitWindowOnScreen()
    }

    /// Pulls a saved frame that is larger than, or off, the screen back inside it.
    private func fitWindowOnScreen() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var f = window.frame
        f.size.width = min(max(f.width, window.minSize.width), v.width)
        f.size.height = min(max(f.height, window.minSize.height), v.height)
        f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        if f != window.frame { window.setFrame(f, display: false) }
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing only hides the orbit; the pill keeps watching.
        sender.orderOut(nil)
        schedulePillUpdate()
        return false
    }

    private var spaceHeld = false

    private func releaseSpace() {
        guard spaceHeld else { return }
        spaceHeld = false
        model.pttUp()
    }

    /// Typing in a text field (the new-session prompt) keeps Space as a normal key.
    private var editingText: Bool { window.firstResponder is NSTextView }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        // Space held in the orbit window is push-to-talk, like ⌥ Space everywhere else.
        if e.keyCode == 49 {
            if e.type == .keyUp {
                if spaceHeld { releaseSpace(); return nil }
                return e
            }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.window === window, mods.isEmpty, !editingText {
                if !e.isARepeat, !spaceHeld {
                    spaceHeld = true
                    model.pttDown()
                }
                return nil
            }
            return e
        }
        guard e.type == .keyDown else { return e }
        if e.keyCode == 53 { // Esc
            return model.escape() ? nil : e
        }
        if e.modifierFlags.contains(.command), !e.modifierFlags.contains(.shift),
           let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n), e.window === window {
            model.focusTab(n)
            return nil
        }
        return e
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: ui("About Claude Companion", "Über Claude Companion"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: ui("Hide Claude Companion", "Claude Companion ausblenden"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: ui("Quit Claude Companion", "Claude Companion beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: ui("Edit", "Bearbeiten"))
        edit.addItem(withTitle: ui("Undo", "Widerrufen"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: ui("Redo", "Wiederholen"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: ui("Cut", "Ausschneiden"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: ui("Copy", "Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: ui("Paste", "Einsetzen"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: ui("Select All", "Alles auswählen"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: ui("Window", "Fenster"))
        let show = NSMenuItem(title: ui("Show Companion", "Companion zeigen"), action: #selector(showFromMenu), keyEquivalent: "0")
        show.target = self
        win.addItem(show)
        win.addItem(withTitle: ui("Minimize", "Im Dock ablegen"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: ui("Close", "Schließen"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    @objc private func showFromMenu() { showWindow() }

    // MARK: pill

    private func buildPill() {
        pill = PillPanel()
        pillHost = FirstClickHostingView(rootView: AnyView(EmptyView()))
        pillHost.sizingOptions = [] // the panel's frame is set from PillView.size
        pill.contentView = pillHost
        refreshMetrics()
    }

    private func pillScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func refreshMetrics() {
        guard let screen = pillScreen() else { return }
        let top = screen.safeAreaInsets.top
        if top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            metrics = PillMetrics(hasNotch: true, notchWidth: screen.frame.width - l.width - r.width, stripHeight: top)
        } else {
            metrics = PillMetrics(hasNotch: false, notchWidth: 0, stripHeight: 34)
        }
        if metrics != lastPillMetrics {
            lastPillMetrics = metrics
            pillHost.rootView = AnyView(PillView(metrics: metrics).environmentObject(model))
        }
    }

    private func schedulePillUpdate() {
        guard !pillScheduled else { return }
        pillScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.pillScheduled = false
            self?.updatePill()
        }
    }

    /// The orbit window in front hides the pill; anywhere else, the pill is in the notch.
    private func updatePill() {
        guard let window, let pill, let screen = pillScreen() else { return }
        refreshMetrics()
        let mainVisible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        let still = ProcessInfo.processInfo.environment["COMPANION_STILL"] != nil
        if model.mainVisible != (mainVisible && !still) { model.mainVisible = mainVisible && !still }
        let orbitInFront = NSApp.isActive && mainVisible && window.isKeyWindow
        if model.pillVisible != (!orbitInFront && !still) { model.pillVisible = !orbitInFront && !still }
        if orbitInFront {
            if pill.isVisible { pill.orderOut(nil) }
            if model.pillExpanded { model.pillExpanded = false }
            return
        }
        let size = PillView.size(model, metrics)
        let topY = metrics.hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY - 6
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                           y: (topY - size.height).rounded(),
                           width: size.width.rounded(), height: size.height.rounded())
        if frame != lastPillFrame {
            lastPillFrame = frame
            pill.setFrame(frame, display: true)
        }
        if !pill.isVisible { pill.orderFrontRegardless() }
    }
}
