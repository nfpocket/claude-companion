import AppKit

/// The layout, workspace and Ghostty settings: the header's layout button and the View menu.
@MainActor
enum LayoutMenu {
    /// Shows the menu under the mouse (the header button).
    static func popUp(_ model: AppModel) {
        let menu = NSMenu()
        fill(menu, model: model, menuBar: false)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Adds the items to `menu`. The menu bar's View menu also gets zoom and ⌘K.
    static func fill(_ menu: NSMenu, model: AppModel, menuBar: Bool) {
        func item(_ title: String, _ symbol: String? = nil, on: Bool = false, enabled: Bool = true,
                  key: String = "", mods: NSEvent.ModifierFlags = [.command], _ run: @escaping () -> Void) {
            let i = ClosureMenuItem(title, run)
            i.state = on ? .on : .off
            i.isEnabled = enabled
            if let symbol, !menuBar { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            if !key.isEmpty { i.keyEquivalent = key; i.keyEquivalentModifierMask = mods }
            menu.addItem(i)
        }
        menu.autoenablesItems = false

        menu.addItem(.sectionHeader(title: ui("Layout", "Layout")))
        let now = model.layoutChoice == .auto ? " (" + model.autoLayout.label + ")" : ""
        for (n, c) in LayoutChoice.allCases.enumerated() {
            let title = c == .auto ? ui("Automatic", "Automatisch") + now : (c.mode?.label ?? "")
            item(title, c.symbol, on: model.layoutChoice == c, key: "\(n)", mods: [.command, .control]) { model.choose(c) }
        }
        if menuBar {
            menu.addItem(.separator())
            // Always enabled: the menu is built once for its shortcuts; off the graph they do nothing.
            item(ui("Zoom In (graph)", "Vergrößern (Graph)"), key: "+") { model.canvas(.zoomIn) }
            item(ui("Zoom Out (graph)", "Verkleinern (Graph)"), key: "-") { model.canvas(.zoomOut) }
            item(ui("Fit Everything in the Window", "Alles ins Fenster einpassen"), key: "0", mods: [.command, .option]) {
                model.canvas(.fit)
            }
            item(ui("Back to the Starting Size", "Zurück zur Ausgangsgröße")) { model.canvas(.reset) }
            menu.addItem(.separator())
            item(ui("Go to Session or Project…", "Zu Session oder Projekt …"), key: "k") { model.openSwitcher() }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: ui("Projects", "Projekte")))
        item(ui("Group projects into workspaces (their folder)", "Projekte in Workspaces gruppieren (ihr Ordner)"),
             "square.stack.3d.up", on: model.useWorkspaces) { model.useWorkspaces.toggle() }
        item(ui("Short names in a workspace (acme-api → api)", "Kurze Namen im Workspace (acme-api → api)"),
             "textformat.size.smaller", on: model.dropPrefix, enabled: model.useWorkspaces) { model.dropPrefix.toggle() }
        let code = NSMenuItem(title: ui("Workspaces come from", "Workspaces kommen aus") + ": "
                              + (model.codeFolder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ui("the folders, automatically", "den Ordnern, automatisch")),
                              action: nil, keyEquivalent: "")
        code.isEnabled = model.useWorkspaces
        if !menuBar { code.image = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: nil) }
        let sub = NSMenu()
        let auto = ClosureMenuItem(ui("Automatic: the folder above each repo", "Automatisch: der Ordner über jedem Repo")) { model.codeFolder = nil }
        auto.state = model.codeFolder == nil ? .on : .off
        sub.addItem(auto)
        if let cf = model.codeFolder {
            let cur = ClosureMenuItem(ui("Subfolders of ", "Unterordner von ") + (cf as NSString).abbreviatingWithTildeInPath) {}
            cur.state = .on
            sub.addItem(cur)
        }
        sub.addItem(ClosureMenuItem(ui("Choose a code folder…", "Code-Ordner wählen …")) { chooseCodeFolder(model) })
        code.submenu = sub
        menu.addItem(code)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Ghostty"))
        item(ui("Open new sessions in their workspace’s window", "Neue Sessions im Fenster ihres Workspace öffnen"),
             "macwindow.on.rectangle", on: model.ghosttyPerWorkspace, enabled: model.useWorkspaces) { model.ghosttyPerWorkspace.toggle() }
        item(ui("Name tabs after their project (api · Release PR)", "Tabs nach ihrem Projekt benennen (api · Release-PR)"),
             "character.cursor.ibeam", on: model.nameTabs) { model.nameTabs.toggle() }
        item(ui("Sort the tabs by project", "Tabs nach Projekt sortieren"), "arrow.up.arrow.down", enabled: Ghostty.isRunning) {
            model.sortGhosttyTabs()
        }
    }

    static func chooseCodeFolder(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = ui("The folder that holds your workspaces (like ~/Projects): each folder in it is a workspace.",
                           "Der Ordner mit deinen Workspaces (etwa ~/Projects): Jeder Ordner darin ist ein Workspace.")
        panel.directoryURL = URL(fileURLWithPath: model.codeFolder ?? Paths.home.path)
        if panel.runModal() == .OK, let url = panel.url { model.codeFolder = url.path }
    }
}
