import SwiftUI

/// A line in the ⌘K switcher.
struct SwitcherItem: Identifiable, Equatable {
    enum Kind { case session, workspace, repo, start, terminal }
    enum Section: Int { case sessions, projects, actions }
    let kind: Kind
    let title: String
    let detail: String
    /// The session's id, or the folder for the rest.
    let target: String
    var status: SessionStatus? = nil
    var shortcut: String? = nil

    var id: String { "\(kind)|\(target)" }

    var section: Section {
        switch kind {
        case .session: return .sessions
        case .workspace, .repo: return .projects
        case .start, .terminal: return .actions
        }
    }
}

enum Switcher {
    /// What matches `query`: sessions, then workspaces and projects, then what you can do with
    /// the best project. Every word typed has to appear; words that start a name count more.
    static func results(_ query: String, sessions: [Session], tree: ProjectTree, pinned: [String] = []) -> [SwitcherItem] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        func score(_ hay: String) -> Int? {
            let h = hay.lowercased()
            var total = 0
            for w in words {
                guard h.contains(w) else { return nil }
                let starts = h.hasPrefix(w) || h.contains(" " + w) || h.contains("/" + w) || h.contains("-" + w)
                    || h.contains("›" + w) || h.contains("› " + w)
                total += starts ? 3 : 1
            }
            return total
        }

        // Sessions: with nothing typed, the ones that want a look.
        var found: [(SwitcherItem, Int)] = []
        for s in sessions {
            let hay = "\(s.title) \(s.place) \(s.folder)"
            let urgent = s.isUrgent || (s.status == .done && s.unseen)
            guard let sc = words.isEmpty ? (urgent ? 1 : nil) : score(hay) else { continue }
            found.append((SwitcherItem(kind: .session, title: s.title, detail: s.place.isEmpty ? s.folder : s.place,
                                       target: s.id, status: s.status, shortcut: s.shortcut), sc * 10 + (7 - s.rank)))
        }
        let sessionItems = found.sorted { $0.1 > $1.1 }.prefix(words.isEmpty ? 6 : 7).map(\.0)

        // Workspaces and projects, with and without sessions.
        var projects: [(SwitcherItem, Int)] = []
        func count(_ n: Int) -> String { ui("\(n) session\(n == 1 ? "" : "s")", "\(n) Session\(n == 1 ? "" : "s")") }
        for w in tree.workspaces {
            let detail = count(w.sessions.count) + " · " + ui("\(w.repoCount) projects", "\(w.repoCount) Projekte")
            let item = SwitcherItem(kind: .workspace, title: w.name, detail: detail, target: w.id)
            if words.isEmpty {
                if pinned.contains(w.id) || !w.sessions.isEmpty { projects.append((item, pinned.contains(w.id) ? 2 : 1)) }
            } else if let sc = score(w.name) {
                projects.append((item, sc * 10 + 2))
            }
        }
        var repos: [(root: String, place: String, n: Int)] = tree.repos.map { ($0.root, tree.place(ofRepo: $0.root), $0.sessions.count) }
        repos += tree.allIdle.map { ($0.root, tree.place(ofRepo: $0.root), 0) }
        for r in repos {
            let item = SwitcherItem(kind: .repo, title: r.place, detail: r.n > 0 ? count(r.n) : ui("no session", "keine Session"), target: r.root)
            if words.isEmpty {
                if pinned.contains(r.root) { projects.append((item, 2)) }
            } else if let sc = score(r.place + " " + Projects.name(r.root)) {
                projects.append((item, sc * 10 + (r.n > 0 ? 1 : 0)))
            }
        }
        let projectItems = projects.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.title.count < b.0.title.count }
            .prefix(6).map(\.0)

        // What to do with the best project.
        var actions: [SwitcherItem] = []
        if !words.isEmpty, let best = projectItems.first {
            actions.append(SwitcherItem(kind: .start, title: ui("Start a session in \(best.title)…", "Session in \(best.title) starten …"),
                                        detail: (best.target as NSString).abbreviatingWithTildeInPath, target: best.target))
            actions.append(SwitcherItem(kind: .terminal, title: ui("Open \(best.title) in Ghostty", "\(best.title) in Ghostty öffnen"),
                                        detail: ui("a plain shell, in its workspace’s window", "eine einfache Shell, im Fenster des Workspace"),
                                        target: best.target))
        }
        return sessionItems + projectItems + actions
    }
}

extension AppModel {
    var switcherResults: [SwitcherItem] { Switcher.results(switcherQuery, sessions: sessions, tree: tree, pinned: pinned) }

    func openSwitcher() {
        switcherQuery = ""
        switcherIndex = 0
        switcherOpen = true
    }

    func switcherMove(_ d: Int) {
        let n = switcherResults.count
        guard n > 0 else { return }
        switcherIndex = min(n - 1, max(0, switcherIndex + d))
    }

    /// Return: a session's Ghostty tab, a project in the sidebar. ⌘ Return: the session here.
    func switcherRun(_ item: SwitcherItem? = nil, here: Bool = false) {
        let list = switcherResults
        guard let item = item ?? (list.indices.contains(switcherIndex) ? list[switcherIndex] : nil) else { return }
        switcherOpen = false
        let folder = (item.target as NSString).expandingTildeInPath
        switch item.kind {
        case .session:
            guard let s = session(item.target) else { return }
            if here {
                if selectedId != s.id { select(s.id) }
            } else {
                focus(s)
            }
        case .workspace: reveal(.workspace(item.target))
        case .repo: reveal(.repo(item.target))
        case .start: openNewSession(in: folder)
        case .terminal: openTerminal(in: folder)
        }
    }
}

/// ⌘K: type a few letters of a session, project or workspace and go there.
struct SwitcherView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        let items = model.switcherResults
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundColor(Theme.muted)
                TextField(ui("Session, project or workspace…", "Session, Projekt oder Workspace …"), text: $model.switcherQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                Text("esc").font(Theme.mono(11)).foregroundColor(Theme.faint)
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        if items.isEmpty {
                            Text(ui("Nothing matches “\(model.switcherQuery)”.", "Nichts passt zu „\(model.switcherQuery)“."))
                                .font(.system(size: 13)).foregroundColor(Theme.muted)
                                .padding(.horizontal, 12).padding(.vertical, 14)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            if i == 0 || items[i - 1].section != item.section { heading(item.section) }
                            row(item, selected: i == model.switcherIndex)
                                .id(item.id)
                                .onTapGesture { model.switcherIndex = i; model.switcherRun(item) }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.switcherIndex) { _, i in
                    if items.indices.contains(i) { proxy.scrollTo(items[i].id) }
                }
            }
            .frame(maxHeight: 420)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 14) {
                hint("↑↓", ui("move", "wählen"))
                hint("↩", ui("open", "öffnen"))
                hint("⌘↩", ui("show the session here", "Session hier zeigen"))
                Spacer()
                Text(ui("or hold ⌥ Space and say it", "oder ⌥ Leertaste halten und sagen"))
                    .font(.system(size: 11)).foregroundColor(Theme.faint)
            }
            .padding(.horizontal, 18)
            .frame(height: 36)
        }
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderHi, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .onAppear { focused = true }
        .onChange(of: model.switcherQuery) { _, _ in model.switcherIndex = 0 }
    }

    private func heading(_ s: SwitcherItem.Section) -> some View {
        let text: String
        switch s {
        case .sessions: text = ui("Sessions", "Sessions")
        case .projects: text = ui("Workspaces and projects", "Workspaces und Projekte")
        case .actions: text = ui("Do", "Tun")
        }
        return Text(text.uppercased())
            .font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundColor(Theme.faint)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private func row(_ item: SwitcherItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                switch item.kind {
                case .session: StatusBadge(status: item.status ?? .idle, size: 26)
                case .workspace: icon("square.stack.3d.up", Theme.accentLight)
                case .repo: icon("folder", Theme.muted)
                case .start: icon("plus.bubble", Theme.accent)
                case .terminal: icon("terminal", Theme.muted)
                }
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(item.kind == .repo ? Theme.mono(13).weight(.medium) : .system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(item.detail).font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let k = item.shortcut { Text(k).font(Theme.mono(11)).foregroundColor(Theme.faint) }
            if selected {
                Text(item.kind == .session ? "Ghostty ↩" : "↩").font(Theme.mono(11)).foregroundColor(Theme.muted)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.raised : Color.clear))
        .contentShape(Rectangle())
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 14)).foregroundColor(color)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(Theme.mono(11).weight(.semibold)).foregroundColor(Theme.muted)
            Text(text).font(.system(size: 11)).foregroundColor(Theme.faint)
        }
    }
}
