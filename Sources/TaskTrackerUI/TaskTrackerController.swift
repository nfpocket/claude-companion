import AppKit
import Carbon.HIToolbox
import SwiftUI
import TaskTrackerCore

/// Lets the SwiftUI content react to the popover opening and ask it to close.
@MainActor
@Observable
final class PanelState {
    private(set) var openCount = 0
    @ObservationIgnored var close: () -> Void = {}

    func didOpen() { openCount += 1 }
}

/// Task Tracker inside Claude Companion: the menu bar item with its ⌃⌥T popover (tasks and the
/// menu of checks and ideas), plus reminders. It was the whole Task Tracker app; the companion now
/// owns it and shares its store and menu with the orbit window.
@MainActor
public final class TaskTrackerController: NSObject {
    public static let hotKeyLabel = "⌃⌥T"

    public let store = TaskStore(fileURL: TaskStore.defaultFileURL)
    public let menu = MenuPanel()
    private let panel = PanelState()
    private lazy var outline = TaskOutlineController(store: store)
    private lazy var reminders = Reminders(store: store, center: Reminders.notificationCenter)
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var sidebarOutline: TaskOutlineController?
    private let sidebarPanel = PanelState()

    public override init() { super.init() }

    /// Session actions for the context menus of tasks and menu items.
    public var sessionBridge: SessionBridge? {
        didSet {
            outline.sessionBridge = sessionBridge
            sidebarOutline?.sessionBridge = sessionBridge
            menu.sessionBridge = sessionBridge
        }
    }

    /// The whole Task Tracker (its tabs, the list with sections and folders, the menu) for a
    /// sidebar. Same store and menu as the popover, its own selection.
    public func makeSidebar() -> AnyView {
        let outline = sidebarOutline ?? TaskOutlineController(store: store)
        outline.sessionBridge = sessionBridge
        sidebarOutline = outline
        return AnyView(ContentView(store: store, panel: sidebarPanel, outline: outline, menu: menu, embedded: true))
    }

    /// Whether ⌃⌥T could be registered (another app may own it).
    public var hotKeyRegistered: Bool { hotKey != nil }

    public func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Tasks")
        item.button?.target = self
        item.button?.action = #selector(togglePopoverFromButton)
        statusItem = item

        let content = NSHostingController(rootView: ContentView(store: store, panel: panel, outline: outline, menu: menu))
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.behavior = .transient
        panel.close = { [weak self] in self?.popover.performClose(nil) }
        outline.onCancel = panel.close
        reminders.showTask = { [weak self] id in self?.show(id) }
        reminders.start()
        menu.start()

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.togglePopover()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            let key: CommandKey? = switch event.keyCode {
            case 36, 76: .lineBreak // Return, Enter
            default: event.charactersIgnoringModifiers == "v" ? .paste : nil
            }
            guard let key else { return event }
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { self?.handle(key, inWindow: windowNumber) ?? false }
            return handled ? nil : event
        }
    }

    /// Shortcuts text fields would otherwise get wrong: ⌘V with an image (they'd drop it) and
    /// ⌘Return (they'd ignore it instead of starting a new line).
    private enum CommandKey {
        case paste, lineBreak
    }

    private func handle(_ key: CommandKey, inWindow windowNumber: Int) -> Bool {
        guard let window = NSApp.window(withWindowNumber: windowNumber) else { return false }
        let target: TaskOutlineController
        if window === popover.contentViewController?.view.window {
            target = outline
        } else if let sidebar = sidebarOutline, window === sidebar.outlineView.window {
            target = sidebar
        } else {
            return false
        }
        return switch key {
        case .paste: target.pasteImageIfNeeded(firstResponder: window.firstResponder)
        case .lineBreak: target.insertLineBreakIfNeeded(firstResponder: window.firstResponder)
        }
    }

    @objc private func togglePopoverFromButton() { togglePopover() }

    public func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        panel.didOpen()
    }

    /// Opens the list with a task selected.
    public func show(_ taskID: UUID) {
        if popover.isShown {
            outline.select(taskID)
        } else {
            outline.selectOnOpen = taskID
            togglePopover()
        }
    }
}
