import AppKit
import Foundation

/// The three ways the window shows sessions.
enum StageMode: String {
    /// Sessions around the avatar: a handful.
    case orbit
    /// Avatar → workspaces → projects → sessions, on a canvas you can pan and zoom.
    case graph
    /// A Finder-like tree of every workspace and project beside the one you picked.
    case sidebar

    /// The layout for this many sessions: small stays small.
    static func auto(sessions: Int, repos: Int, topLevel: Int) -> StageMode {
        if sessions >= 16 || repos >= 10 { return .sidebar }
        if sessions >= 7 && topLevel >= 2 { return .graph }
        return .orbit
    }
}

/// The layout you picked: automatic, or one of them always.
enum LayoutChoice: String, CaseIterable, Identifiable {
    case auto, orbit, graph, sidebar
    var id: String { rawValue }

    var mode: StageMode? {
        switch self {
        case .auto: return nil
        case .orbit: return .orbit
        case .graph: return .graph
        case .sidebar: return .sidebar
        }
    }

    static func of(_ m: StageMode) -> LayoutChoice {
        switch m {
        case .orbit: return .orbit
        case .graph: return .graph
        case .sidebar: return .sidebar
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .orbit: return "circle.dashed"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .sidebar: return "sidebar.left"
        }
    }
}

extension StageMode {
    var label: String {
        switch self {
        case .orbit: return ui("Orbit", "Orbit")
        case .graph: return ui("Workspace graph", "Workspace-Graph")
        case .sidebar: return ui("Sidebar", "Seitenleiste")
        }
    }
}

/// What the sidebar layout shows on the right.
enum NavItem: Hashable {
    case needs, unseen, all
    case workspace(String)
    case repo(String)

    var key: String {
        switch self {
        case .needs: return "needs"
        case .unseen: return "unseen"
        case .all: return "all"
        case .workspace(let id): return "ws:" + id
        case .repo(let id): return "repo:" + id
        }
    }

    init?(key: String) {
        switch key {
        case "needs": self = .needs
        case "unseen": self = .unseen
        case "all": self = .all
        default:
            if key.hasPrefix("ws:") { self = .workspace(String(key.dropFirst(3))) }
            else if key.hasPrefix("repo:") { self = .repo(String(key.dropFirst(5))) }
            else { return nil }
        }
    }
}

/// A one-off request to the graph canvas (from the menu or the keyboard).
struct CanvasRequest: Equatable {
    let id = UUID()
    let command: CanvasCommand
}

extension ProjectTree {
    /// The same tree with every session passed through `f`.
    mutating func mapSessions(_ f: (Session) -> Session) {
        for w in workspaces.indices {
            for r in workspaces[w].repos.indices { workspaces[w].repos[r].sessions = workspaces[w].repos[r].sessions.map(f) }
        }
        for r in loose.indices { loose[r].sessions = loose[r].sessions.map(f) }
    }
}

extension Session {
    /// Wants a look: waiting on you, or failed and not seen yet.
    var isUrgent: Bool { status == .needs || (status == .failed && unseen) }
}

extension AppModel {
    // MARK: layout

    /// Works out the automatic layout, unless you're looking at the window (`force`: it's just
    /// coming to the front, so now is the moment).
    func refreshAutoLayout(force: Bool = false) {
        guard force || !windowInFront || !layoutPrimed else { return }
        let m = StageMode.auto(sessions: sessions.count, repos: tree.repos.count, topLevel: tree.topLevelCount)
        // Settled once the sessions are in: at launch the window is in front before they are.
        layoutPrimed = storeReported
        guard m != autoLayout else { return }
        autoLayout = m
        if layoutChoice == .auto { canvas = CanvasView() }
    }

    /// Shows a layout: a picked one stays; "automatic" follows the sessions again.
    func choose(_ c: LayoutChoice) {
        layoutChoice = c
        if c == .auto { refreshAutoLayout(force: true) }
    }

    func canvas(_ c: CanvasCommand) {
        if stageMode != .graph, c != .reset { return }
        canvasCommand = CanvasRequest(command: c)
    }

    /// The canvas leaves scroll and pinch alone while something covers it.
    var canvasBlocked: Bool { switcherOpen || showHelp || pending?.kind == .newSession }

    // MARK: projects

    func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    func togglePinned(_ id: String) {
        if let i = pinned.firstIndex(of: id) { pinned.remove(at: i) } else { pinned.append(id) }
    }

    func isHiddenWhenEmpty(_ id: String) -> Bool { hiddenWhenEmpty.contains(id) }

    func toggleHiddenWhenEmpty(_ id: String) {
        if hiddenWhenEmpty.contains(id) { hiddenWhenEmpty.remove(id) } else { hiddenWhenEmpty.insert(id) }
    }

    /// The graph: only this workspace open.
    func foldOthers(than id: String) {
        var c = collapsedProjects
        for w in tree.workspaces { if w.id == id { c.remove(w.id) } else { c.insert(w.id) } }
        collapsedProjects = c
    }

    /// Shows a workspace or project in the sidebar layout (switching to it if need be).
    func reveal(_ item: NavItem) {
        nav = item
        switch item {
        case .workspace(let id): navOpen.insert(id)
        case .repo(let id): if let w = tree.workspace(ofRepo: id) { navOpen.insert(w.id) }
        default: break
        }
        guard stageMode != .sidebar else { return }
        if layoutChoice == .auto { autoLayout = .sidebar } else { layoutChoice = .sidebar }
    }

    /// The folder of a workspace or project, for "start a session here".
    func folder(of item: NavItem) -> String? {
        switch item {
        case .workspace(let id), .repo(let id): return (id as NSString).expandingTildeInPath
        default: return nil
        }
    }

    // MARK: Ghostty windows and tabs

    /// The workspace a folder belongs to ("" outside one), to pick its Ghostty window.
    func workspaceKey(forFolder folder: String) -> String {
        guard useWorkspaces else { return "" }
        let root = Projects.root(of: folder)
        if let w = tree.workspace(ofRepo: root) { return w.id }
        if tree.workspace(root) != nil { return (root as NSString).standardizingPath }
        let parents = Workspaces.projectParents(knownRepos + [root])
        return Workspaces.folder(of: root, parents: parents, codeFolder: codeFolder) ?? ""
    }

    /// Where a new tab for `folder` goes: the window that mostly holds its workspace's sessions,
    /// or a new window for it. Without workspaces, the front window as before.
    func ghosttyTarget(forFolder folder: String) -> GhosttyTarget {
        guard ghosttyPerWorkspace, tree.hasWorkspaces, !snap.terms.isEmpty else { return .front }
        let key = workspaceKey(forFolder: folder)
        let placed: [(window: String, key: String)] = sessions.compactMap { s in
            guard let tty = s.tty, let t = snap.terms[tty] else { return nil }
            return (t.windowId, tree.workspace(ofRepo: s.project.isEmpty ? s.cwd : s.project)?.id ?? "")
        }
        if let w = GhosttyTabs.window(for: key, among: placed) { return .window(w) }
        return .newWindow
    }

    /// Names each session's Ghostty tab "✅ api · Release PR" (keeping its status icon), and gives
    /// tabs whose session ended their own title back. A tab with splits takes the name of its
    /// most urgent session. Nothing happens while Ghostty didn't answer the last poll.
    func syncTabNames() {
        guard !Demo.on, ghosttyPolled, snap.ok, !tabNamesInFlight else { return }
        var want: [String: String] = [:]
        if nameTabs {
            var project: [String: String] = [:]
            for g in tree.repos { for s in g.sessions { project[s.id] = g.name } }
            // Sessions come most urgent first, so the first one in a tab names it.
            for s in sessions {
                guard let tty = s.tty, let term = snap.terms[tty], !term.tabId.isEmpty, want[term.tabId] == nil else { continue }
                want[term.tabId] = GhosttyTabs.name(s, project: project[s.id] ?? s.folder, ownTitle: term.title)
            }
        }
        var change: [Ghostty.TabName] = []
        for (tab, name) in want where appliedTabNames[tab] != name {
            change.append(.init(tab: tab, name: name, was: appliedTabNames[tab] ?? ""))
        }
        for (tab, was) in appliedTabNames where want[tab] == nil {
            change.append(.init(tab: tab, name: "", was: was))
        }
        guard !change.isEmpty else { return }
        tabNamesInFlight = true
        ghostty.setTabNames(change) { [weak self] ok in
            guard let self else { return }
            self.tabNamesInFlight = false
            // Only what Ghostty took counts; a failed script is tried again on the next change.
            guard ok else { return }
            var applied = self.appliedTabNames
            for c in change { applied[c.tab] = c.name.isEmpty ? nil : c.name }
            self.appliedTabNames = applied
        }
    }

    /// On quit: every tab the companion named gets its own title back (best effort, 2 s at most).
    func clearTabNames() {
        guard !appliedTabNames.isEmpty else { return }
        let change = appliedTabNames.map { Ghostty.TabName(tab: $0.key, name: "", was: $0.value) }
        ghostty.setTabNames(change, wait: true) { [weak self] ok in
            if ok { self?.appliedTabNames = [:] }
        }
    }

    /// Puts each Ghostty window's tabs in order: by workspace, then project.
    func sortGhosttyTabs() {
        var byTab: [String: String] = [:]
        for g in tree.repos {
            let ws = g.workspace.flatMap { tree.workspace($0)?.name } ?? "~"
            for s in g.sessions {
                guard let tty = s.tty, let t = snap.terms[tty] else { continue }
                byTab[t.tabId] = "\(ws)\u{1}\(g.name)\u{1}\(s.title)"
            }
        }
        var moved = 0
        for (window, tabs) in snap.tabs {
            let order = GhosttyTabs.sorted(tabs, keys: byTab)
            if order != tabs { moved += 1; ghostty.reorder(window: window, tabs: order) }
        }
        flash(moved == 0 ? ui("Ghostty’s tabs are already in order.", "Die Ghostty-Tabs sind schon sortiert.")
                         : ui("Sorted the tabs by project.", "Tabs nach Projekt sortiert."))
    }
}

/// Pure helpers for naming and placing Ghostty tabs.
enum GhosttyTabs {
    /// The window most of whose Claude sessions are in workspace `key` (nil when none is).
    static func window(for key: String, among placed: [(window: String, key: String)]) -> String? {
        var byWindow: [String: [String: Int]] = [:]
        for p in placed { byWindow[p.window, default: [:]][p.key, default: 0] += 1 }
        var best: (window: String, n: Int)?
        for (w, counts) in byWindow.sorted(by: { $0.key < $1.key }) {
            let total = counts.values.reduce(0, +), n = counts[key] ?? 0
            if n * 2 > total, n > (best?.n ?? 0) { best = (w, n) }
        }
        return best?.window
    }

    /// "✅ api · Release PR 05.11.": the status icon the tab had before (from its own title,
    /// set by Claude Code or a tab-status script), then project and title. ❗ while it needs
    /// you; without an icon of its own, one for its status.
    static func name(_ s: Session, project: String, ownTitle: String? = nil) -> String {
        let mark: String
        if s.status == .needs {
            mark = "❗"
        } else if let own = ownTitle.flatMap(icon(ofTitle:)) {
            mark = own
        } else {
            switch s.status {
            case .working: mark = "◐"
            case .shell: mark = "⏳"
            case .done: mark = "✅"
            case .failed: mark = "❌"
            case .idle, .needs: mark = "✳"
            }
        }
        var title = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = title.unicodeScalars.first, !CharacterSet.alphanumerics.contains(f) { title.removeFirst() }
        if title.count > 34 { title = String(title.prefix(33)).trimmingCharacters(in: .whitespaces) + "…" }
        return title.isEmpty ? "\(mark) \(project)" : "\(mark) \(project) · \(title)"
    }

    /// The icon at the front of a title ("✅ Fix login" → "✅"), if it starts with one. A
    /// spinner frame (braille dots) reads as one glyph, so the name doesn't change every poll.
    static func icon(ofTitle t: String) -> String? {
        guard let first = t.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first.map(String.init),
              !first.isEmpty, first.count <= 2,
              !first.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        if first.unicodeScalars.allSatisfy({ (0x2800...0x28FF).contains($0.value) }) { return "◐" }
        return first
    }

    /// Tab ids in the order they should be: tabs with a session by their key, the rest after
    /// them in the order they were.
    static func sorted(_ tabs: [String], keys: [String: String]) -> [String] {
        let known = tabs.filter { keys[$0] != nil }.sorted { a, b in
            keys[a]!.localizedCaseInsensitiveCompare(keys[b]!) == .orderedAscending
        }
        return known + tabs.filter { keys[$0] == nil }
    }
}
