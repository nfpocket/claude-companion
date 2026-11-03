import AppKit
import SwiftUI
import TaskTrackerCore

/// What the app hosting Task Tracker offers on a task or a menu item: start a Claude Code session
/// with it, or paste it into a running one. Claude Companion sets it; without it the context menus
/// are what they always were.
@MainActor
public struct SessionBridge {
    public struct Target: Identifiable {
        public let id: String
        public let title: String
        /// False for a session that can't take text right now (gone, or waiting on a prompt).
        public let enabled: Bool

        public init(id: String, title: String, enabled: Bool) {
            self.id = id
            self.title = title
            self.enabled = enabled
        }
    }

    /// The menu titles in the host's language ("Start a new session with it", "Paste into a
    /// session", "Choose a folder…", "No sessions open").
    public var text: (String) -> String
    public var folders: () -> [String]
    public var sessions: () -> [Target]
    public var start: (_ text: String, _ folder: String) -> Void
    public var paste: (_ text: String, _ sessionID: String) -> Void

    public init(text: @escaping (String) -> String, folders: @escaping () -> [String],
                sessions: @escaping () -> [Target],
                start: @escaping (_ text: String, _ folder: String) -> Void,
                paste: @escaping (_ text: String, _ sessionID: String) -> Void) {
        self.text = text
        self.folders = folders
        self.sessions = sessions
        self.start = start
        self.paste = paste
    }

    static func folderLabel(_ path: String) -> String {
        (path as NSString).lastPathComponent + "   " + (path as NSString).abbreviatingWithTildeInPath
    }

    func chooseFolder(thenStart content: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folders().first.map { URL(fileURLWithPath: $0) }
        if panel.runModal() == .OK, let url = panel.url { start(content, url.path) }
    }

    /// The two submenus, for AppKit context menus. `content` is read when an item is chosen.
    func menuItems(_ content: @escaping () -> String) -> [NSMenuItem] {
        let startMenu = NSMenu()
        for folder in folders().prefix(12) {
            startMenu.addItem(ActionMenuItem(Self.folderLabel(folder)) { start(content(), folder) })
        }
        if !startMenu.items.isEmpty { startMenu.addItem(.separator()) }
        startMenu.addItem(ActionMenuItem(text("Choose a folder…")) { chooseFolder(thenStart: content()) })
        let startItem = NSMenuItem(title: text("Start a new session with it"), action: nil, keyEquivalent: "")
        startItem.submenu = startMenu

        let pasteMenu = NSMenu()
        pasteMenu.autoenablesItems = false
        let targets = sessions()
        if targets.isEmpty {
            let none = NSMenuItem(title: text("No sessions open"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            pasteMenu.addItem(none)
        }
        for target in targets {
            let item = ActionMenuItem(target.title) { paste(content(), target.id) }
            item.isEnabled = target.enabled
            pasteMenu.addItem(item)
        }
        let pasteItem = NSMenuItem(title: text("Paste into a session"), action: nil, keyEquivalent: "")
        pasteItem.submenu = pasteMenu
        return [startItem, pasteItem]
    }
}

/// The same two submenus for SwiftUI context menus.
struct SessionBridgeMenus: View {
    let bridge: SessionBridge
    let content: String

    var body: some View {
        Menu(bridge.text("Start a new session with it")) {
            ForEach(bridge.folders().prefix(12), id: \.self) { folder in
                Button(SessionBridge.folderLabel(folder)) { bridge.start(content, folder) }
            }
            Divider()
            Button(bridge.text("Choose a folder…")) { bridge.chooseFolder(thenStart: content) }
        }
        Menu(bridge.text("Paste into a session")) {
            let targets = bridge.sessions()
            if targets.isEmpty { Text(bridge.text("No sessions open")) }
            ForEach(targets) { target in
                Button(target.title) { bridge.paste(content, target.id) }
                    .disabled(!target.enabled)
            }
        }
    }
}

extension MenuItem {
    /// What goes into a session's prompt for this check or idea.
    func sessionText(pr: MenuPR) -> String {
        var lines = [text]
        if let location, !location.isEmpty { lines.append("Where: \(location)") }
        if let why, !why.isEmpty { lines.append("Why: \(why)") }
        lines.append("PR: \(pr.repo)#\(pr.number)" + (pr.url.map { " \($0)" } ?? ""))
        return lines.joined(separator: "\n")
    }
}
