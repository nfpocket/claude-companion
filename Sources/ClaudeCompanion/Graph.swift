import SwiftUI

/// A line in the graph: avatar → workspace or project, workspace → project, project → session.
struct GraphEdge: Identifiable, Equatable {
    let from: CGPoint
    let to: CGPoint
    /// Down, then across (stacked layout); otherwise a sideways S-curve.
    let elbow: Bool
    /// The node the line ends at, or (for a session) the node it hangs off.
    let group: String
    let session: String?
    var id: String { session.map { "s:" + $0 } ?? "g:" + group }
}

/// A node of the graph, a workspace or a project, with what hangs off it: its projects (an open
/// workspace) or session cards (an open project, or a folded workspace's urgent sessions).
struct GraphItem: Equatable {
    enum Kind { case workspace, repo }
    let id: String
    let kind: Kind
    /// Its column, 0 right beside the avatar. Projects in workspaces are in column 1.
    let column: Int
    var children: [GraphItem] = []
    var cards: [String] = []

    var depth: Int { 1 + (children.map(\.depth).max() ?? 0) }

    /// The graph for a project tree: workspaces, then their projects, then sessions. A folded
    /// workspace keeps what needs you beside it; a folded project shows no sessions.
    static func items(_ tree: ProjectTree, collapsed: Set<String>) -> [GraphItem] {
        let col = tree.hasWorkspaces ? 1 : 0
        func repo(_ g: ProjectGroup, _ c: Int) -> GraphItem {
            let id = nodeId(g)
            return GraphItem(id: id, kind: .repo, column: c, cards: collapsed.contains(id) ? [] : g.sessions.map(\.id))
        }
        // Workspaces without a session are for the sidebar, not the graph.
        var out: [GraphItem] = tree.workspaces.filter { !$0.repos.isEmpty }.map { w in
            if collapsed.contains(w.id) {
                let urgent = w.sessions.filter { $0.status == .needs || ($0.status == .failed && $0.unseen) }
                return GraphItem(id: w.id, kind: .workspace, column: 0, cards: urgent.map(\.id))
            }
            return GraphItem(id: w.id, kind: .workspace, column: 0, children: w.repos.map { repo($0, 1) })
        }
        out += tree.loose.map { repo($0, col) }
        return out
    }

    /// A project's node id: its folder, except for sessions in a workspace's own folder, whose
    /// "project" is the workspace's folder too.
    static func nodeId(_ g: ProjectGroup) -> String {
        g.workspace != nil && g.workspace == ProjectTree.normalized(g.root) ? g.id + "#folder" : g.id
    }
}

/// Where everything goes in the graph: the avatar, a node per workspace and project, and each
/// project's sessions beside it, joined by curves. Three arrangements, whichever shows things
/// biggest: on both sides of the avatar, all on its right, or (on a narrow stage) stacked, each
/// node's contents under it. The graph has its own size (`size`); the canvas shows it at `scale`
/// (big enough to read) and pans and zooms it.
struct GraphLayout {
    enum Mode { case twoSides, oneSide, stacked }

    static let cardW: CGFloat = 272
    static let cardH: CGFloat = 84
    static let cardGap: CGFloat = 10
    /// Between the first-level blocks, and between the projects of one workspace.
    static let groupGap: CGFloat = 26
    static let innerGap: CGFloat = 14
    static let nodeW: CGFloat = 200
    static let nodeH: CGFloat = 54
    /// The avatar with its caption (beside the projects).
    static let avatarW: CGFloat = 180
    static let avatarH: CGFloat = 120 + 66
    /// Avatar → node, node → node, and node → cards.
    static let toNode: CGFloat = 56
    static let toCard: CGFloat = 48
    /// Stacked: how far each level sits in from the one above.
    static let indent: CGFloat = 30
    static let margin: CGFloat = 24
    /// The smallest scale the graph starts at; past that, the canvas pans.
    static let minScale: CGFloat = 0.75

    /// One side: the node columns and the cards, with the space before each.
    static func sideW(columns: Int) -> CGFloat {
        toNode + CGFloat(columns) * nodeW + CGFloat(columns - 1) * toNode + toCard + cardW
    }

    let mode: Mode
    let columns: Int
    /// The graph's own size, before scaling.
    let size: CGSize
    /// The scale it starts at: as big as fits, up to 1, but not below `minScale`.
    let scale: CGFloat
    /// The scale at which all of it fits the stage (up to 1).
    let fitScale: CGFloat
    let avatar: CGPoint
    let avatarSize: CGFloat
    /// The caption under the avatar (not when stacked, where room is short).
    var showsCaption: Bool { mode != .stacked }
    private(set) var edges: [GraphEdge] = []
    private var nodes: [String: CGPoint] = [:]
    private var cards: [String: CGPoint] = [:]

    var twoSided: Bool { mode == .twoSides }
    /// Bigger than the stage at `scale`: the canvas pans.
    var scrolls: Bool { fitScale < scale - 0.001 }
    func node(_ id: String) -> CGPoint? { nodes[id] }
    /// Nil for a session that isn't shown (in a folded project).
    func card(_ id: String) -> CGPoint? { cards[id] }
    /// The avatar and, beside the projects, its caption: kept clear of everything else.
    var avatarBox: CGRect {
        showsCaption
            ? CGRect(x: avatar.x - GraphLayout.avatarW / 2, y: avatar.y - avatarSize / 2, width: GraphLayout.avatarW, height: GraphLayout.avatarH)
            : CGRect(x: avatar.x - avatarSize / 2, y: avatar.y - avatarSize / 2, width: avatarSize, height: avatarSize)
    }

    // MARK: sizes

    /// A node's height beside the avatar: the node, or what hangs off it when that's taller.
    static func blockHeight(_ item: GraphItem) -> CGFloat {
        if !item.children.isEmpty {
            return max(nodeH, stackHeight(item.children.map(blockHeight), gap: innerGap))
        }
        return max(nodeH, cardsHeight(item.cards.count))
    }

    /// Stacked: the node with everything under it.
    static func stackedHeight(_ item: GraphItem) -> CGFloat {
        if !item.children.isEmpty {
            return nodeH + item.children.reduce(0) { $0 + cardGap + stackedHeight($1) }
        }
        return nodeH + (item.cards.isEmpty ? 0 : cardGap + cardsHeight(item.cards.count))
    }

    private static func cardsHeight(_ n: Int) -> CGFloat {
        CGFloat(n) * cardH + CGFloat(max(0, n - 1)) * cardGap
    }

    private static func stackHeight(_ heights: [CGFloat], gap: CGFloat = groupGap) -> CGFloat {
        heights.reduce(0, +) + gap * CGFloat(max(0, heights.count - 1))
    }

    init(items: [GraphItem], stage: CGRect) {
        columns = max(1, (items.map { $0.column + $0.depth }.max() ?? 1))
        let heights = items.map(GraphLayout.blockHeight)
        let sideW = GraphLayout.sideW(columns: columns)
        // Both sides: each block, in order, goes to the shorter side (the first to the right).
        var right: [Int] = [], left: [Int] = []
        var rh: CGFloat = 0, lh: CGFloat = 0
        for (i, h) in heights.enumerated() {
            if rh <= lh { right.append(i); rh += h + GraphLayout.groupGap } else { left.append(i); lh += h + GraphLayout.groupGap }
        }
        let oneSize = CGSize(width: GraphLayout.avatarW + sideW,
                             height: max(GraphLayout.avatarH, GraphLayout.stackHeight(heights)))
        let twoSize = CGSize(width: GraphLayout.avatarW + 2 * sideW,
                             height: max(GraphLayout.avatarH, GraphLayout.stackHeight(right.map { heights[$0] }),
                                         GraphLayout.stackHeight(left.map { heights[$0] })))
        let room = CGSize(width: max(1, stage.width - 2 * GraphLayout.margin), height: max(1, stage.height - 2 * GraphLayout.margin))
        func fit(_ s: CGSize) -> CGFloat { min(1, room.width / s.width, room.height / s.height) }
        let one = fit(oneSize), two = left.isEmpty ? 0 : fit(twoSize)
        // Beside the avatar works whenever its width fits at a readable size: the canvas pans
        // up and down for the rest.
        let oneWide = room.width / oneSize.width >= GraphLayout.minScale
        let twoWide = !left.isEmpty && room.width / twoSize.width >= GraphLayout.minScale

        if oneWide || twoWide {
            // Whichever shows things bigger; both sides (the avatar in the middle) on a tie.
            mode = twoWide && (!oneWide || two >= one - 0.001) ? .twoSides : .oneSide
            if mode == .oneSide { right = Array(heights.indices); left = [] }
            size = mode == .twoSides ? twoSize : oneSize
            fitScale = mode == .twoSides ? two : one
            scale = min(1, room.width / size.width, max(GraphLayout.minScale, room.height / size.height))
            avatarSize = 120
            let avatarX = mode == .twoSides ? sideW + GraphLayout.avatarW / 2 : GraphLayout.avatarW / 2
            // The avatar and its caption, centered top to bottom; in a graph taller than the
            // stage, in the middle of the part you see first.
            let seen = max(GraphLayout.avatarH, min(size.height, room.height / scale))
            avatar = CGPoint(x: avatarX, y: (seen - GraphLayout.avatarH) / 2 + avatarSize / 2)
            for (side, dir) in [(right, CGFloat(1)), (left, CGFloat(-1))] {
                var y = (size.height - GraphLayout.stackHeight(side.map { heights[$0] })) / 2
                let from = CGPoint(x: avatar.x + dir * (avatarSize / 2 + 6), y: avatar.y)
                for i in side {
                    placeBeside(items[i], top: y, height: heights[i], dir: dir, from: from)
                    y += heights[i] + GraphLayout.groupGap
                }
            }
        } else {
            mode = .stacked
            avatarSize = 72
            func width(_ item: GraphItem, _ level: Int) -> CGFloat {
                let own = CGFloat(level) * GraphLayout.indent + (item.cards.isEmpty ? GraphLayout.nodeW
                    : max(GraphLayout.nodeW, GraphLayout.indent + GraphLayout.cardW))
                return item.children.map { width($0, level + 1) }.reduce(own, max)
            }
            let w = items.map { width($0, 0) }.reduce(max(GraphLayout.nodeW, avatarSize), max)
            avatar = CGPoint(x: w / 2, y: avatarSize / 2)
            let height = avatarSize + 20 + GraphLayout.stackHeight(items.map(GraphLayout.stackedHeight))
            size = CGSize(width: w, height: height)
            fitScale = min(1, room.width / w, room.height / height)
            scale = min(1, room.width / w, max(GraphLayout.minScale, room.height / height))
            var y = avatarSize + 20
            for item in items {
                placeStacked(item, top: y, level: 0)
                y += GraphLayout.stackedHeight(item) + GraphLayout.groupGap
            }
        }
    }

    /// A node beside the avatar (`dir` 1 to its right, -1 to its left), and what hangs off it.
    private mutating func placeBeside(_ item: GraphItem, top y: CGFloat, height h: CGFloat, dir: CGFloat, from: CGPoint) {
        let W = GraphLayout.nodeW
        let nodeOffset = GraphLayout.avatarW / 2 + GraphLayout.toNode + CGFloat(item.column) * (W + GraphLayout.toNode) + W / 2
        let cardOffset = GraphLayout.avatarW / 2 + GraphLayout.sideW(columns: columns) - GraphLayout.cardW / 2
        let node = CGPoint(x: avatar.x + dir * nodeOffset, y: y + h / 2)
        nodes[item.id] = node
        edges.append(GraphEdge(from: from, to: CGPoint(x: node.x - dir * W / 2, y: node.y),
                               elbow: false, group: item.id, session: nil))
        let out = CGPoint(x: node.x + dir * W / 2, y: node.y)
        if !item.children.isEmpty {
            let hs = item.children.map(GraphLayout.blockHeight)
            var cy = y + (h - GraphLayout.stackHeight(hs, gap: GraphLayout.innerGap)) / 2
            for (child, ch) in zip(item.children, hs) {
                placeBeside(child, top: cy, height: ch, dir: dir, from: out)
                cy += ch + GraphLayout.innerGap
            }
            return
        }
        var cy = y + (h - GraphLayout.cardsHeight(item.cards.count)) / 2 + GraphLayout.cardH / 2
        for id in item.cards {
            let p = CGPoint(x: avatar.x + dir * cardOffset, y: cy)
            cards[id] = p
            edges.append(GraphEdge(from: out, to: CGPoint(x: p.x - dir * GraphLayout.cardW / 2, y: p.y),
                                   elbow: false, group: item.id, session: id))
            cy += GraphLayout.cardH + GraphLayout.cardGap
        }
    }

    /// Stacked: the node, then (set in a little) its projects or its cards.
    private mutating func placeStacked(_ item: GraphItem, top: CGFloat, level: Int) {
        let x = CGFloat(level) * GraphLayout.indent
        let node = CGPoint(x: x + GraphLayout.nodeW / 2, y: top + GraphLayout.nodeH / 2)
        nodes[item.id] = node
        let spine = x + 15
        var y = top + GraphLayout.nodeH
        if !item.children.isEmpty {
            for child in item.children {
                y += GraphLayout.cardGap
                placeStacked(child, top: y, level: level + 1)
                edges.append(GraphEdge(from: CGPoint(x: spine, y: node.y + GraphLayout.nodeH / 2),
                                       to: CGPoint(x: x + GraphLayout.indent, y: y + GraphLayout.nodeH / 2),
                                       elbow: true, group: child.id, session: nil))
                y += GraphLayout.stackedHeight(child)
            }
            return
        }
        for id in item.cards {
            y += GraphLayout.cardGap
            let p = CGPoint(x: x + GraphLayout.indent + GraphLayout.cardW / 2, y: y + GraphLayout.cardH / 2)
            cards[id] = p
            edges.append(GraphEdge(from: CGPoint(x: spine, y: node.y + GraphLayout.nodeH / 2),
                                   to: CGPoint(x: x + GraphLayout.indent, y: p.y),
                                   elbow: true, group: item.id, session: id))
            y += GraphLayout.cardH
        }
    }
}

/// An edge of the graph: a sideways S-curve, or (stacked) straight down and round into the card.
struct EdgeShape: Shape {
    var from: CGPoint
    var to: CGPoint
    var elbow = false

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(from.x, from.y), .init(to.x, to.y)) }
        set {
            from = CGPoint(x: newValue.first.first, y: newValue.first.second)
            to = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        if elbow {
            let r = min(10, abs(to.y - from.y), abs(to.x - from.x))
            p.addLine(to: CGPoint(x: from.x, y: to.y - r))
            p.addQuadCurve(to: CGPoint(x: from.x + r, y: to.y), control: CGPoint(x: from.x, y: to.y))
            p.addLine(to: to)
        } else {
            let mid = (to.x - from.x) / 2
            p.addCurve(to: to, control1: CGPoint(x: from.x + mid, y: from.y), control2: CGPoint(x: to.x - mid, y: to.y))
        }
        return p
    }
}

/// A workspace or project in the graph: its name and how its sessions stand. Click it (or
/// right-click) for its folder: Finder, Ghostty, an editor, a new session; the chevron folds it.
struct GraphNode: View {
    @EnvironmentObject var model: AppModel
    var id: String
    var kind: GraphItem.Kind
    var name: String
    var path: String
    var sessions: [Session]
    /// Projects without a session, for a workspace's line ("+ 9").
    var idle = 0
    var collapsed: Bool
    var highlight: Color?
    var dimmed = false
    @State private var hover = false

    var body: some View {
        let actions = ProjectAction.all(id: id, path: path, kind: kind, collapsed: collapsed, model: model)
        HStack(spacing: 0) {
            Button { ProjectAction.popUp(actions) } label: {
                HStack(spacing: 10) {
                    Image(systemName: kind == .workspace ? (collapsed ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                                                         : (collapsed ? "folder.fill" : "folder"))
                        .font(.system(size: kind == .workspace ? 14 : 15))
                        .foregroundColor(needs ? SessionStatus.needs.color : (kind == .workspace ? Theme.accentLight : Theme.muted))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Projects.shortName(name, max: 20))
                            .font(kind == .workspace ? .system(size: 13, weight: .bold) : Theme.mono(12).weight(.semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        StatusRow(sessions: sessions, limit: kind == .workspace ? 5 : 7)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help((path as NSString).abbreviatingWithTildeInPath
                  + (idle > 0 ? " · " + ui("\(idle) more projects without sessions", "\(idle) weitere Projekte ohne Sessions") : ""))
            Button { model.toggleCollapsed(id) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.muted)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 34, height: GraphLayout.nodeH)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(ProjectAction.foldTitle(kind, collapsed))
        }
        .frame(width: GraphLayout.nodeW, height: GraphLayout.nodeH)
        .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Theme.raised : (kind == .workspace ? Theme.surfaceHi : Theme.surface)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: highlight != nil ? 2 : 1))
        .opacity(dimmed ? 0.45 : 1)
        .onHover { hover = $0 }
        .contextMenu {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                if let a { Button { a.run() } label: { Label(a.title, systemImage: a.symbol) } } else { Divider() }
            }
        }
        .animation(.easeOut(duration: 0.18), value: collapsed)
    }

    private var needs: Bool { sessions.contains { $0.status == .needs } }

    private var border: Color {
        if let h = highlight { return h }
        return needs ? SessionStatus.needs.color.opacity(0.6) : Theme.borderHi
    }
}

/// One small status icon per session, most urgent first.
struct StatusRow: View {
    var sessions: [Session]
    var limit: Int
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 5) {
            ForEach(sessions.prefix(limit)) { s in StatusGlyph(status: s.status, size: size) }
            if sessions.count > limit {
                Text("+\(sessions.count - limit)").font(.system(size: size, weight: .semibold)).foregroundColor(Theme.faint)
            }
        }
    }
}

/// What you can do with a project's folder, for its click menu and its right-click menu.
struct ProjectAction {
    let title: String
    let symbol: String
    let run: () -> Void

    static func foldTitle(_ kind: GraphItem.Kind, _ collapsed: Bool) -> String {
        if kind == .workspace {
            return collapsed ? ui("Show its projects", "Projekte zeigen") : ui("Fold its projects away", "Projekte einklappen")
        }
        return collapsed ? ui("Show its sessions", "Sessions zeigen") : ui("Fold its sessions away", "Sessions einklappen")
    }

    /// What you can do with a folder: open it, start a session in it, pin it. `collapsed` adds
    /// folding (for the graph); nil leaves it out. nil in the list stands for a separator.
    @MainActor
    static func all(id: String, path rawPath: String, kind: GraphItem.Kind, collapsed: Bool? = nil, model: AppModel) -> [ProjectAction?] {
        let path = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // Pins go by folder (a graph node's id can carry a suffix).
        let pin = kind == .workspace ? id : rawPath
        var list: [ProjectAction?] = [
            ProjectAction(title: ui("Start a session here…", "Hier eine Session starten …"), symbol: "plus.bubble") {
                model.openNewSession(in: path)
            },
            nil,
            ProjectAction(title: ui("Open in Finder", "Im Finder öffnen"), symbol: "folder") { NSWorkspace.shared.open(url) },
            ProjectAction(title: ui("Open in Ghostty", "In Ghostty öffnen"), symbol: "terminal") { model.openTerminal(in: path) },
        ]
        for e in Editor.installed {
            list.append(ProjectAction(title: ui("Open in \(e.name)", "In \(e.name) öffnen"), symbol: "chevron.left.forwardslash.chevron.right") {
                NSWorkspace.shared.open([url], withApplicationAt: e.url, configuration: .init())
            })
        }
        list += [
            ProjectAction(title: ui("Copy path", "Pfad kopieren"), symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            nil,
            model.isPinned(pin)
                ? ProjectAction(title: ui("Unpin", "Nicht mehr anheften"), symbol: "pin.slash") { model.togglePinned(pin) }
                : ProjectAction(title: ui("Pin to the sidebar", "In der Seitenleiste anheften"), symbol: "pin") { model.togglePinned(pin) },
        ]
        if kind == .workspace {
            list.append(model.isHiddenWhenEmpty(id)
                ? ProjectAction(title: ui("Always show it", "Immer zeigen"), symbol: "eye") { model.toggleHiddenWhenEmpty(id) }
                : ProjectAction(title: ui("Hide it while nothing runs", "Ausblenden, solange nichts läuft"), symbol: "eye.slash") {
                    model.toggleHiddenWhenEmpty(id)
                })
        }
        if let collapsed {
            list.append(nil)
            list.append(ProjectAction(title: foldTitle(kind, collapsed), symbol: collapsed ? "chevron.down" : "chevron.right") {
                model.toggleCollapsed(id)
            })
            if kind == .workspace {
                list.append(ProjectAction(title: ui("Fold all the others", "Alle anderen einklappen"), symbol: "rectangle.compress.vertical") {
                    model.foldOthers(than: id)
                })
            }
        }
        return list
    }

    /// Shows the actions as a menu at the mouse.
    @MainActor
    static func popUp(_ actions: [ProjectAction?]) {
        let menu = NSMenu()
        for a in actions {
            guard let a else { menu.addItem(.separator()); continue }
            let item = ClosureMenuItem(a.title, a.run)
            item.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// Code editors on this Mac that can open a folder.
struct Editor: Identifiable {
    let name: String
    let url: URL
    var id: String { name }

    static let installed: [Editor] = [
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Zed", "dev.zed.Zed"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Nova", "com.panic.Nova"),
    ].compactMap { name, id in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { Editor(name: name, url: $0) }
    }
}
