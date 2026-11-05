import SwiftUI

/// The layout for many sessions: on the left a tree of every workspace and project (as in
/// Finder) under "Needs you", "Finished, not seen" and "All"; on the right the one you picked.
struct SidebarStage: View {
    @EnvironmentObject var model: AppModel
    static let navWidth: CGFloat = 252

    var body: some View {
        HStack(spacing: 0) {
            Navigator()
                .frame(width: SidebarStage.navWidth)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            FocusPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Navigator

struct Navigator: View {
    @EnvironmentObject var model: AppModel
    /// Workspaces whose projects without a session are listed too.
    @State private var showIdle: Set<String> = []

    var body: some View {
        let s = model.sessions
        let tree = model.tree
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                MiniAvatar(mode: model.avatar, height: 26, level: { model.voiceLevel() })
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.avatarTitle).font(.system(size: 13, weight: .semibold))
                    Text(model.avatarSubtitle).font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .onTapGesture { _ = model.escape() }

            Button { model.openSwitcher() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(Theme.muted)
                    Text(ui("Go to…", "Gehe zu …")).foregroundColor(Theme.faint)
                    Spacer()
                    Text("⌘K").font(Theme.mono(11)).foregroundColor(Theme.faint)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    smart(.needs, "exclamationmark.circle", L("Needs you"), s.filter(\.isUrgent).count, SessionStatus.needs.color)
                    smart(.unseen, "checkmark.circle", ui("Finished, not seen", "Fertig, nicht angesehen"),
                          s.filter { $0.status == .done && $0.unseen }.count, SessionStatus.done.color)
                    smart(.all, "square.grid.2x2", ui("All sessions", "Alle Sessions"), s.count, Theme.muted)

                    let pins = pinnedRows(tree)
                    if !pins.isEmpty {
                        heading(ui("Pinned", "Angeheftet"))
                        ForEach(pins, id: \.id) { p in p.view }
                    }

                    heading(tree.hasWorkspaces ? ui("Workspaces", "Workspaces") : ui("Projects", "Projekte"))
                    ForEach(visibleWorkspaces(tree)) { w in
                        workspaceRow(w)
                        if model.navOpen.contains(w.id) {
                            ForEach(sortedRepos(w.repos)) { g in repoRow(g.id, g.name, g.sessions, indent: 1) }
                            idleRows(w.id, w.idle, indent: 1)
                        }
                    }
                    ForEach(sortedRepos(tree.loose)) { g in repoRow(g.id, g.name, g.sessions, indent: 0) }
                    idleRows("", tree.looseIdle, indent: 0)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
        }
        .background(Theme.panel)
    }

    private func visibleWorkspaces(_ tree: ProjectTree) -> [Workspace] {
        tree.workspaces
            .filter { !$0.sessions.isEmpty || !model.isHiddenWhenEmpty($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sortedRepos(_ list: [ProjectGroup]) -> [ProjectGroup] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct PinRow { let id: String; let view: AnyView }

    private func pinnedRows(_ tree: ProjectTree) -> [PinRow] {
        model.pinned.compactMap { id in
            if let w = tree.workspace(id) {
                return PinRow(id: id, view: AnyView(row(.workspace(id), icon: "square.stack.3d.up", name: w.name,
                                                        sessions: w.sessions, indent: 0, kind: .workspace, path: id)))
            }
            if let g = tree.repo(id) {
                return PinRow(id: id, view: AnyView(row(.repo(id), icon: "folder", name: tree.place(ofRepo: id),
                                                        sessions: g.sessions, indent: 0, kind: .repo, path: g.root)))
            }
            if tree.allIdle.contains(where: { $0.root == id }) {
                return PinRow(id: id, view: AnyView(row(.repo(id), icon: "folder", name: tree.place(ofRepo: id),
                                                        sessions: [], indent: 0, kind: .repo, path: id, dim: true)))
            }
            return nil
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundColor(Theme.faint)
            .padding(.leading, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func smart(_ item: NavItem, _ icon: String, _ title: String, _ count: Int, _ color: Color) -> some View {
        NavRow(selected: model.nav == item, indent: 0, action: { model.nav = item }) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundColor(count > 0 ? color : Theme.faint)
                .frame(width: 16)
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)").font(.system(size: 11, weight: .bold))
                    .foregroundColor(item == .all ? Theme.muted : color)
            }
        }
    }

    private func workspaceRow(_ w: Workspace) -> some View {
        let open = model.navOpen.contains(w.id)
        return NavRow(selected: model.nav == .workspace(w.id), indent: 0,
                      action: {
                          model.nav = .workspace(w.id)
                          model.navOpen.insert(w.id)
                      }) {
            Button { toggleOpen(w.id) } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.faint)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Image(systemName: "square.stack.3d.up").font(.system(size: 12)).foregroundColor(Theme.accentLight).frame(width: 16)
            Text(w.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Tally(sessions: w.sessions)
        }
        .contextMenu { menu(ProjectAction.all(id: w.id, path: w.id, kind: .workspace, model: model)) }
        .help((w.id as NSString).abbreviatingWithTildeInPath + " · " + ui("\(w.repoCount) projects", "\(w.repoCount) Projekte"))
    }

    private func repoRow(_ id: String, _ name: String, _ sessions: [Session], indent: Int) -> some View {
        row(.repo(id), icon: "folder", name: name, sessions: sessions, indent: indent, kind: .repo, path: id)
    }

    private func row(_ item: NavItem, icon: String, name: String, sessions: [Session], indent: Int,
                     kind: GraphItem.Kind, path: String, dim: Bool = false) -> some View {
        NavRow(selected: model.nav == item, indent: indent, action: { model.nav = item }) {
            if indent == 0 && kind == .repo { Color.clear.frame(width: 12, height: 1) }
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(Theme.muted).frame(width: 16)
            Text(name).font(Theme.mono(12)).lineLimit(1).truncationMode(.middle)
                .foregroundColor(dim ? Theme.faint : Theme.text)
            Spacer(minLength: 4)
            Tally(sessions: sessions)
        }
        .contextMenu { menu(ProjectAction.all(id: path, path: path, kind: kind, model: model)) }
        .help((path as NSString).abbreviatingWithTildeInPath)
    }

    /// "9 without sessions", which lists them when clicked.
    @ViewBuilder
    private func idleRows(_ key: String, _ idle: [IdleRepo], indent: Int) -> some View {
        if !idle.isEmpty {
            let shown = showIdle.contains(key)
            if shown {
                ForEach(idle) { r in
                    row(.repo(r.root), icon: "folder", name: r.name, sessions: [], indent: indent, kind: .repo, path: r.root, dim: true)
                }
            }
            Button {
                if shown { showIdle.remove(key) } else { showIdle.insert(key) }
            } label: {
                HStack(spacing: 6) {
                    Color.clear.frame(width: CGFloat(indent) * 16 + 30, height: 1)
                    Text(shown ? ui("Hide the ones without sessions", "Die ohne Sessions ausblenden")
                               : ui("\(idle.count) more without sessions", "\(idle.count) weitere ohne Sessions"))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.faint)
                    Spacer()
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleOpen(_ id: String) {
        if model.navOpen.contains(id) { model.navOpen.remove(id) } else { model.navOpen.insert(id) }
    }

    @ViewBuilder
    private func menu(_ actions: [ProjectAction?]) -> some View {
        ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
            if let a { Button { a.run() } label: { Label(a.title, systemImage: a.symbol) } } else { Divider() }
        }
    }
}

/// A row of the navigator: highlighted when picked or under the mouse.
struct NavRow<Content: View>: View {
    var selected: Bool
    var indent: Int
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if indent > 0 { Color.clear.frame(width: CGFloat(indent) * 16, height: 1) }
                content()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.raised : (hover ? Theme.surface : Color.clear)))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(Theme.accent).frame(width: 3, height: 16).offset(x: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.text)
        .onHover { hover = $0 }
    }
}

/// How a group of sessions stands, in a few numbers: what needs you, what failed, what's
/// finished and not seen; otherwise how many there are.
struct Tally: View {
    var sessions: [Session]
    /// At most this many numbers, the most pressing first.
    var limit = 3

    var body: some View {
        let parts: [(SessionStatus, Int)] = [
            (.needs, sessions.filter { $0.status == .needs }.count),
            (.failed, sessions.filter { $0.status == .failed && $0.unseen }.count),
            (.done, sessions.filter { $0.status == .done && $0.unseen }.count),
            (.working, sessions.filter { $0.status == .working || $0.status == .shell }.count),
        ].filter { $0.1 > 0 }
        HStack(spacing: 7) {
            ForEach(parts.prefix(limit), id: \.0) { s, n in part(s, n) }
            if parts.isEmpty, !sessions.isEmpty {
                Text("\(sessions.count)").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.faint)
            }
        }
        .fixedSize()
    }

    private func part(_ s: SessionStatus, _ n: Int) -> some View {
        HStack(spacing: 3) {
            StatusGlyph(status: s, size: 9)
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundColor(s.color)
        }
    }
}

// MARK: - Focus

/// The right side of the sidebar layout: what you picked, as cards.
struct FocusPane: View {
    @EnvironmentObject var model: AppModel

    private static let columns = [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 12, alignment: .top)]

    var body: some View {
        let item = resolved
        VStack(alignment: .leading, spacing: 0) {
            header(item)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView(.vertical, showsIndicators: true) {
                content(item)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.nav)
    }

    /// The picked item, or All when what was picked is gone.
    private var resolved: NavItem {
        let t = model.tree
        switch model.nav {
        case .workspace(let id): return t.workspace(id) != nil ? model.nav : .all
        case .repo(let id):
            return t.repo(id) != nil || t.allIdle.contains(where: { $0.root == id }) ? model.nav : .all
        default: return model.nav
        }
    }

    // MARK: header

    @ViewBuilder
    private func header(_ item: NavItem) -> some View {
        let t = model.tree
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                switch item {
                case .needs: title(L("Needs you"))
                case .unseen: title(ui("Finished, not seen", "Fertig, nicht angesehen"))
                case .all: title(ui("All sessions", "Alle Sessions"))
                case .workspace(let id): title(t.workspace(id)?.name ?? "")
                case .repo(let id):
                    if let w = t.workspace(ofRepo: id) {
                        HStack(spacing: 6) {
                            Text(w.name).font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.muted)
                            Text("›").font(.system(size: 18)).foregroundColor(Theme.faint)
                            title(t.place(ofRepo: id).components(separatedBy: " › ").last ?? "")
                        }
                    } else {
                        title(t.place(ofRepo: id))
                    }
                }
                Text(subtitle(item)).font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let folder = model.folder(of: item) {
                Button { model.openNewSession(in: folder) } label: {
                    Label(ui("New session", "Neue Session"), systemImage: "plus")
                }
                .buttonStyle(ChipButtonStyle())
                let kind: GraphItem.Kind = { if case .workspace = item { return .workspace }; return .repo }()
                Button {
                    ProjectAction.popUp(ProjectAction.all(id: id(item), path: folder, kind: kind, model: model))
                } label: {
                    Image(systemName: "ellipsis").frame(width: 16)
                }
                .buttonStyle(ChromeButtonStyle())
                .help(ui("Open it, pin it, …", "Öffnen, anheften, …"))
            } else {
                Button(L("What needs me?")) { model.askNeeds() }.buttonStyle(ChipButtonStyle())
            }
        }
    }

    private func id(_ item: NavItem) -> String {
        switch item {
        case .workspace(let id), .repo(let id): return id
        default: return ""
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 18, weight: .semibold)).lineLimit(1)
    }

    private func subtitle(_ item: NavItem) -> String {
        let t = model.tree
        let s = model.sessions
        switch item {
        case .needs:
            let n = s.filter(\.isUrgent).count
            let busy = s.filter { $0.status == .working || $0.status == .shell }.count
            return n == 0 ? ui("Nothing waits on you · \(busy) working", "Nichts wartet auf dich · \(busy) arbeiten")
                          : ui("Waiting on you, or stopped on an error", "Warten auf dich oder sind mit einem Fehler gestoppt")
        case .unseen:
            return ui("Done since you last looked", "Fertig, seit du zuletzt geschaut hast")
        case .all:
            return ui("\(s.count) sessions in \(t.repos.count) projects", "\(s.count) Sessions in \(t.repos.count) Projekten")
        case .workspace(let id):
            guard let w = t.workspace(id) else { return "" }
            return ui("\(w.sessions.count) sessions · \(w.repoCount) projects", "\(w.sessions.count) Sessions · \(w.repoCount) Projekte")
                + " · " + (w.id as NSString).abbreviatingWithTildeInPath
        case .repo(let id):
            let n = t.repo(id)?.sessions.count ?? 0
            return ui("\(n) session\(n == 1 ? "" : "s")", "\(n) Session\(n == 1 ? "" : "s")") + " · " + (id as NSString).abbreviatingWithTildeInPath
        }
    }

    // MARK: content

    @ViewBuilder
    private func content(_ item: NavItem) -> some View {
        let t = model.tree
        let s = model.sessions
        switch item {
        case .needs:
            let list = s.filter(\.isUrgent)
            if list.isEmpty {
                empty("checkmark.circle", ui("Nothing needs you", "Nichts braucht dich"),
                      ui("When a session asks for something, it shows up here.", "Wenn eine Session etwas von dir will, erscheint sie hier."))
            } else {
                grid(list, place: true)
            }
        case .unseen:
            let list = s.filter { $0.status == .done && $0.unseen }
            if list.isEmpty {
                empty("eye", ui("You’ve seen everything", "Du hast alles gesehen"),
                      ui("Sessions that finish while you’re away show up here.", "Sessions, die fertig werden, während du weg bist, erscheinen hier."))
            } else {
                grid(list, place: true)
            }
        case .all:
            if s.isEmpty {
                empty("moon.zzz", L("No sessions open"), ui("Start one from a project on the left.", "Starte eine in einem Projekt links."))
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(t.workspaces) { w in
                        section(w.name, w.sessions, action: { model.reveal(.workspace(w.id)) }) { grid(w.sessions, place: false, crumb: true) }
                    }
                    if !t.loose.isEmpty {
                        let list = t.loose.flatMap(\.sessions)
                        section(t.hasWorkspaces ? ui("Other projects", "Andere Projekte") : ui("Projects", "Projekte"), list, action: nil) {
                            grid(list, place: true)
                        }
                    }
                }
            }
        case .workspace(let id):
            if let w = t.workspace(id) {
                VStack(alignment: .leading, spacing: 22) {
                    if w.repos.isEmpty {
                        empty("square.stack.3d.up", ui("No sessions in \(w.name)", "Keine Sessions in \(w.name)"),
                              ui("Start one in any of its projects below.", "Starte eine in einem der Projekte unten."))
                    }
                    ForEach(w.repos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { g in
                        section(g.name, g.sessions, mono: true, action: { model.nav = .repo(g.id) }, folder: g.root) { grid(g.sessions, place: false) }
                    }
                    if !w.idle.isEmpty { idleChips(w.idle) }
                }
            }
        case .repo(let id):
            if let g = t.repo(id) {
                grid(g.sessions, place: false)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    empty("folder", ui("No sessions here", "Hier läuft keine Session"),
                          ui("Start one, or open the project in Ghostty.", "Starte eine, oder öffne das Projekt in Ghostty."))
                    HStack(spacing: 8) {
                        Button { model.openNewSession(in: (id as NSString).expandingTildeInPath) } label: {
                            Label(ui("Start a session here…", "Hier eine Session starten …"), systemImage: "plus.bubble")
                        }
                        .buttonStyle(PrimaryChipStyle())
                        Button { model.openTerminal(in: (id as NSString).expandingTildeInPath) } label: {
                            Label(ui("Open in Ghostty", "In Ghostty öffnen"), systemImage: "terminal")
                        }
                        .buttonStyle(ChipButtonStyle())
                    }
                }
            }
        }
    }

    private func section<C: View>(_ name: String, _ sessions: [Session], mono: Bool = false, action: (() -> Void)?,
                                  folder: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { action?() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mono ? "folder" : "square.stack.3d.up").font(.system(size: 12))
                            .foregroundColor(mono ? Theme.muted : Theme.accentLight)
                        Text(name).font(mono ? Theme.mono(13).weight(.semibold) : .system(size: 14, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(action == nil)
                Tally(sessions: sessions)
                Spacer()
                if let folder {
                    Button { model.openNewSession(in: (folder as NSString).expandingTildeInPath) } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(MiniButtonStyle())
                    .help(ui("Start a session here…", "Hier eine Session starten …"))
                    Button {
                        ProjectAction.popUp(ProjectAction.all(id: folder, path: folder, kind: .repo, model: model))
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(MiniButtonStyle())
                }
            }
            content()
        }
    }

    /// Cards in a grid. `place` puts "acme › api" on each card; `crumb` just the project.
    private func grid(_ list: [Session], place: Bool, crumb: Bool = false) -> some View {
        LazyVGrid(columns: FocusPane.columns, alignment: .leading, spacing: 12) {
            ForEach(list) { s in
                let style = model.cardStyle(s)
                let where_: String? = place ? s.place : (crumb ? s.place.components(separatedBy: " › ").last : nil)
                SessionCard(session: s, menuCount: model.menuPanel?.openCount(forSession: s.id) ?? 0,
                            selected: model.selectedId == s.id, highlight: style.highlight, dimmed: style.dimmed,
                            place: where_) { model.select(s.id) }
            }
        }
    }

    private func idleChips(_ idle: [IdleRepo]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ui("Without sessions", "Ohne Sessions").uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundColor(Theme.muted)
            FlowLayout(spacing: 8) {
                ForEach(idle) { r in
                    Button {
                        ProjectAction.popUp(ProjectAction.all(id: r.root, path: r.root, kind: .repo, model: model))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundColor(Theme.faint)
                            Text(r.name).font(Theme.mono(12)).foregroundColor(Theme.body)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help((r.root as NSString).abbreviatingWithTildeInPath + " · " + ui("click to start a session or open it", "klicken, um eine Session zu starten oder es zu öffnen"))
                }
            }
        }
        .padding(.top, 4)
    }

    private func empty(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 22)).foregroundColor(Theme.faint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(text).font(.system(size: 13)).foregroundColor(Theme.muted)
            }
        }
        .padding(18)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
    }
}

/// Lays its children out in rows, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let h = rows.last.map { $0.y + $0.height } ?? 0
        let w = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
