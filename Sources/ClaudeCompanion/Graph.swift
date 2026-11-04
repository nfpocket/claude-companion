import SwiftUI

/// A line in the graph: avatar → project, or project → session.
struct GraphEdge: Identifiable, Equatable {
    let from: CGPoint
    let to: CGPoint
    /// Down, then across (stacked layout); otherwise a sideways S-curve.
    let elbow: Bool
    let group: String
    let session: String?
    var id: String { session.map { "s:" + $0 } ?? "g:" + group }
}

/// Where everything goes when the sessions are shown by project: the avatar, a node per project,
/// and each project's sessions beside its node, joined by curves. Three arrangements, whichever
/// shows things biggest: projects on both sides of the avatar, all on its right, or (on a narrow
/// stage) stacked, each project's sessions under it. The graph has its own size (`size`) and is
/// scaled down to fit the stage, but not below `minScale`: past that, it scrolls.
struct GraphLayout {
    enum Mode { case twoSides, oneSide, stacked }

    static let cardW: CGFloat = 272
    static let cardH: CGFloat = 84
    static let cardGap: CGFloat = 10
    static let groupGap: CGFloat = 26
    static let nodeW: CGFloat = 200
    static let nodeH: CGFloat = 54
    /// The avatar with its caption (beside the projects).
    static let avatarW: CGFloat = 180
    static let avatarH: CGFloat = 120 + 66
    /// Avatar → node and node → cards.
    static let toNode: CGFloat = 56
    static let toCard: CGFloat = 48
    /// Stacked: how far the cards sit in from their project's node.
    static let indent: CGFloat = 30
    static let margin: CGFloat = 24
    static let minScale: CGFloat = 0.8
    /// One side: node and cards, with the space before each.
    static let sideW: CGFloat = toNode + nodeW + toCard + cardW

    let mode: Mode
    /// The graph's own size, before scaling.
    let size: CGSize
    let scale: CGFloat
    /// Taller than the stage even at `minScale`: scroll it.
    let scrolls: Bool
    let avatar: CGPoint
    let avatarSize: CGFloat
    /// The caption under the avatar (not when stacked, where room is short).
    var showsCaption: Bool { mode != .stacked }
    private(set) var edges: [GraphEdge] = []
    private var nodes: [String: CGPoint] = [:]
    private var cards: [String: CGPoint] = [:]

    var twoSided: Bool { mode == .twoSides }
    func node(_ id: String) -> CGPoint { nodes[id] ?? avatar }
    /// Nil for a session in a collapsed project.
    func card(_ id: String) -> CGPoint? { cards[id] }
    /// The avatar and, beside the projects, its caption: kept clear of everything else.
    var avatarBox: CGRect {
        showsCaption
            ? CGRect(x: avatar.x - GraphLayout.avatarW / 2, y: avatar.y - avatarSize / 2, width: GraphLayout.avatarW, height: GraphLayout.avatarH)
            : CGRect(x: avatar.x - avatarSize / 2, y: avatar.y - avatarSize / 2, width: avatarSize, height: avatarSize)
    }

    /// A project's height beside the avatar: its node, or its stack of cards when that's taller.
    static func blockHeight(_ g: ProjectGroup, collapsed: Bool) -> CGFloat {
        guard !collapsed, !g.sessions.isEmpty else { return nodeH }
        return max(nodeH, cardsHeight(g.sessions.count))
    }

    private static func cardsHeight(_ n: Int) -> CGFloat {
        CGFloat(n) * cardH + CGFloat(max(0, n - 1)) * cardGap
    }

    private static func stackHeight(_ heights: [CGFloat]) -> CGFloat {
        heights.reduce(0, +) + groupGap * CGFloat(max(0, heights.count - 1))
    }

    init(groups: [ProjectGroup], collapsed: Set<String>, stage: CGRect) {
        let heights = groups.map { GraphLayout.blockHeight($0, collapsed: collapsed.contains($0.id)) }
        // Both sides: each project, in order, goes to the shorter side (the first to the right).
        var right: [Int] = [], left: [Int] = []
        var rh: CGFloat = 0, lh: CGFloat = 0
        for (i, h) in heights.enumerated() {
            if rh <= lh { right.append(i); rh += h + GraphLayout.groupGap } else { left.append(i); lh += h + GraphLayout.groupGap }
        }
        let oneSize = CGSize(width: GraphLayout.avatarW + GraphLayout.sideW,
                             height: max(GraphLayout.avatarH, GraphLayout.stackHeight(heights)))
        let twoSize = CGSize(width: GraphLayout.avatarW + 2 * GraphLayout.sideW,
                             height: max(GraphLayout.avatarH, GraphLayout.stackHeight(right.map { heights[$0] }),
                                         GraphLayout.stackHeight(left.map { heights[$0] })))
        let room = CGSize(width: stage.width - 2 * GraphLayout.margin, height: stage.height - 2 * GraphLayout.margin)
        func fit(_ s: CGSize) -> CGFloat { min(1, room.width / s.width, room.height / s.height) }
        let one = fit(oneSize), two = left.isEmpty ? 0 : fit(twoSize)

        if max(one, two) >= GraphLayout.minScale {
            // Whichever shows things bigger; both sides (the avatar in the middle) on a tie.
            mode = two >= one - 0.001 ? .twoSides : .oneSide
            if mode == .oneSide { right = Array(heights.indices); left = [] }
            size = mode == .twoSides ? twoSize : oneSize
            scale = max(one, two)
            scrolls = false
            avatarSize = 120
            let avatarX = mode == .twoSides ? GraphLayout.sideW + GraphLayout.avatarW / 2 : GraphLayout.avatarW / 2
            // The avatar and its caption, centered top to bottom.
            avatar = CGPoint(x: avatarX, y: (size.height - GraphLayout.avatarH) / 2 + avatarSize / 2)
            placeBeside(groups, heights: heights, sides: [(right, 1), (left, -1)], collapsed: collapsed)
        } else {
            mode = .stacked
            avatarSize = 72
            let width = max(GraphLayout.nodeW, GraphLayout.indent + GraphLayout.cardW)
            avatar = CGPoint(x: width / 2, y: avatarSize / 2)
            let height = avatarSize + 20 + GraphLayout.stackHeight(groups.map {
                collapsed.contains($0.id) || $0.sessions.isEmpty
                    ? GraphLayout.nodeH : GraphLayout.nodeH + GraphLayout.cardGap + GraphLayout.cardsHeight($0.sessions.count)
            })
            size = CGSize(width: width, height: height)
            let h = room.height / height
            scale = min(1, room.width / width, max(GraphLayout.minScale, h))
            scrolls = h < scale - 0.001
            placeStacked(groups, collapsed: collapsed)
        }
    }

    /// Projects beside the avatar, `dir` 1 to its right and -1 to its left.
    private mutating func placeBeside(_ groups: [ProjectGroup], heights: [CGFloat], sides: [([Int], CGFloat)], collapsed: Set<String>) {
        let nodeOffset = GraphLayout.avatarW / 2 + GraphLayout.toNode + GraphLayout.nodeW / 2
        let cardOffset = nodeOffset + GraphLayout.nodeW / 2 + GraphLayout.toCard + GraphLayout.cardW / 2
        let r = avatarSize / 2 + 6
        for (side, dir) in sides {
            var y = (size.height - GraphLayout.stackHeight(side.map { heights[$0] })) / 2
            for i in side {
                let g = groups[i], h = heights[i]
                let node = CGPoint(x: avatar.x + dir * nodeOffset, y: y + h / 2)
                nodes[g.id] = node
                edges.append(GraphEdge(from: CGPoint(x: avatar.x + dir * r, y: avatar.y),
                                       to: CGPoint(x: node.x - dir * GraphLayout.nodeW / 2, y: node.y),
                                       elbow: false, group: g.id, session: nil))
                if !collapsed.contains(g.id) {
                    var cy = y + (h - GraphLayout.cardsHeight(g.sessions.count)) / 2 + GraphLayout.cardH / 2
                    for s in g.sessions {
                        let p = CGPoint(x: avatar.x + dir * cardOffset, y: cy)
                        cards[s.id] = p
                        edges.append(GraphEdge(from: CGPoint(x: node.x + dir * GraphLayout.nodeW / 2, y: node.y),
                                               to: CGPoint(x: p.x - dir * GraphLayout.cardW / 2, y: p.y),
                                               elbow: false, group: g.id, session: s.id))
                        cy += GraphLayout.cardH + GraphLayout.cardGap
                    }
                }
                y += h + GraphLayout.groupGap
            }
        }
    }

    /// The avatar on top, then each project's node with its sessions under it, set in a little.
    private mutating func placeStacked(_ groups: [ProjectGroup], collapsed: Set<String>) {
        var y = avatarSize + 20
        for g in groups {
            let node = CGPoint(x: GraphLayout.nodeW / 2, y: y + GraphLayout.nodeH / 2)
            nodes[g.id] = node
            y += GraphLayout.nodeH
            if !collapsed.contains(g.id), !g.sessions.isEmpty {
                y += GraphLayout.cardGap
                for s in g.sessions {
                    let p = CGPoint(x: GraphLayout.indent + GraphLayout.cardW / 2, y: y + GraphLayout.cardH / 2)
                    cards[s.id] = p
                    edges.append(GraphEdge(from: CGPoint(x: 15, y: node.y + GraphLayout.nodeH / 2),
                                           to: CGPoint(x: GraphLayout.indent, y: p.y),
                                           elbow: true, group: g.id, session: s.id))
                    y += GraphLayout.cardH + GraphLayout.cardGap
                }
                y -= GraphLayout.cardGap
            }
            y += GraphLayout.groupGap
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

/// A project in the graph: its name and how its sessions stand. Click it (or right-click) for
/// its folder: Finder, Ghostty, an editor, a new session; the chevron folds its sessions away.
struct ProjectNode: View {
    @EnvironmentObject var model: AppModel
    var group: ProjectGroup
    var collapsed: Bool
    var highlight: Color?
    var dimmed = false
    @State private var hover = false

    var body: some View {
        let actions = ProjectAction.all(group, collapsed: collapsed, model: model)
        HStack(spacing: 0) {
            Button { ProjectAction.popUp(actions) } label: {
                HStack(spacing: 10) {
                    Image(systemName: collapsed ? "folder.fill" : "folder")
                        .font(.system(size: 15))
                        .foregroundColor(needs ? SessionStatus.needs.color : Theme.muted)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Projects.shortName(group.name, max: 20))
                            .font(Theme.mono(12).weight(.semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        StatusRow(sessions: group.sessions, limit: 8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help((group.root as NSString).abbreviatingWithTildeInPath)
            Button { model.toggleCollapsed(group.id) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.muted)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 34, height: GraphLayout.nodeH)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? ui("Show its sessions", "Sessions zeigen") : ui("Fold its sessions away", "Sessions einklappen"))
        }
        .frame(width: GraphLayout.nodeW, height: GraphLayout.nodeH)
        .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Theme.raised : Theme.surface))
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

    private var needs: Bool { group.sessions.contains { $0.status == .needs } }

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

    /// nil stands for a separator.
    @MainActor
    static func all(_ g: ProjectGroup, collapsed: Bool, model: AppModel) -> [ProjectAction?] {
        let path = (g.root as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var list: [ProjectAction?] = [
            ProjectAction(title: ui("Open in Finder", "Im Finder öffnen"), symbol: "folder") { NSWorkspace.shared.open(url) },
            ProjectAction(title: ui("Open in Ghostty", "In Ghostty öffnen"), symbol: "terminal") { model.openTerminal(in: path) },
        ]
        for e in Editor.installed {
            list.append(ProjectAction(title: ui("Open in \(e.name)", "In \(e.name) öffnen"), symbol: "chevron.left.forwardslash.chevron.right") {
                NSWorkspace.shared.open([url], withApplicationAt: e.url, configuration: .init())
            })
        }
        list += [
            nil,
            ProjectAction(title: ui("Start a session here…", "Hier eine Session starten …"), symbol: "plus.bubble") {
                model.openNewSession(in: path)
            },
            ProjectAction(title: ui("Copy path", "Pfad kopieren"), symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            nil,
            ProjectAction(title: collapsed ? ui("Show its sessions", "Sessions zeigen") : ui("Fold its sessions away", "Sessions einklappen"),
                          symbol: collapsed ? "chevron.down" : "chevron.right") { model.toggleCollapsed(g.id) },
        ]
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
