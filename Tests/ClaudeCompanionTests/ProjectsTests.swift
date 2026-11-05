import Foundation
import Testing
@testable import ClaudeCompanion

struct ProjectRootTests {
    let base = FileManager.default.temporaryDirectory
        .appending(path: "ProjectsTests-\(UUID().uuidString)").resolvingSymlinksInPath().path

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func aSubfolderBelongsToItsRepo() throws {
        try mkdir("\(base)/api/.git")
        try mkdir("\(base)/api/app/models")
        #expect(Projects.root(of: "\(base)/api/app/models", home: "/nowhere") == "\(base)/api")
        #expect(Projects.root(of: "\(base)/api", home: "/nowhere") == "\(base)/api")
    }

    @Test func aWorktreeBelongsToTheRepoItWasMadeFrom() throws {
        try mkdir("\(base)/api/.git/worktrees/fix-login")
        try write("../..\n", to: "\(base)/api/.git/worktrees/fix-login/commondir")
        try mkdir("\(base)/api-fix-login/src")
        try write("gitdir: \(base)/api/.git/worktrees/fix-login\n", to: "\(base)/api-fix-login/.git")
        #expect(Projects.root(of: "\(base)/api-fix-login/src", home: "/nowhere") == "\(base)/api")
    }

    @Test func claudeCodeWorktreesCountAsTheirRepo() {
        #expect(Projects.root(of: "/Users/x/Code/api/.claude/worktrees/agent-1/src") == "/Users/x/Code/api")
    }

    @Test func aSubmoduleIsItsOwnProject() throws {
        try mkdir("\(base)/app/.git/modules/vendor-lib")
        try mkdir("\(base)/app/vendor-lib")
        try write("gitdir: ../.git/modules/vendor-lib\n", to: "\(base)/app/vendor-lib/.git")
        #expect(Projects.root(of: "\(base)/app/vendor-lib", home: "/nowhere") == "\(base)/app/vendor-lib")
    }

    @Test func aRepoInTheHomeFolderDoesNotSwallowEverything() throws {
        try mkdir("\(base)/home/.git")
        try mkdir("\(base)/home/Documents/notes")
        #expect(Projects.root(of: "\(base)/home/Documents/notes", home: "\(base)/home") == "\(base)/home/Documents/notes")
        #expect(Projects.root(of: "\(base)/home", home: "\(base)/home") == "\(base)/home")
    }

    @Test func aFolderOutsideAnyRepoIsItsOwnProject() {
        #expect(Projects.root(of: "~/Code/does-not-exist-\(UUID().uuidString)") .hasPrefix("~/Code/does-not-exist-"))
    }
}

struct ProjectGroupTests {
    private func session(_ id: String, _ project: String, _ status: SessionStatus = .working) -> Session {
        var s = Session(id: id, pid: 1, cwd: project, title: id, status: status, since: Date(), tty: nil)
        s.project = project
        return s
    }

    @Test func groupsKeepTheOrbitOrder() {
        let list = [session("a", "/c/api", .needs), session("b", "/c/web"), session("c", "/c/api"), session("d", "/c/web")]
        let g = Projects.groups(list)
        #expect(g.map(\.name) == ["api", "web"])
        #expect(g.map { $0.sessions.map(\.id) } == [["a", "c"], ["b", "d"]])
    }

    @Test func projectsWithTheSameNameShowTheirParent() {
        let g = Projects.groups([session("a", "/work/api"), session("b", "/oss/api"), session("c", "/oss/docs")])
        #expect(g.map(\.name) == ["work/api", "oss/api", "docs"])
    }

    @Test func groupingOnlyWhenItShowsSomething() {
        // One project: nothing to group.
        #expect(Projects.grouping([session("a", "/c/api"), session("b", "/c/api")]) == nil)
        // Every project has one session: the cards' folders say as much.
        #expect(Projects.grouping([session("a", "/c/api"), session("b", "/c/web")]) == nil)
        #expect(Projects.grouping([session("a", "/c/api"), session("b", "/c/web"), session("c", "/c/api")])?.count == 2)
    }

    @Test func longNamesLoseTheirMiddle() {
        #expect(Projects.shortName("api", max: 22) == "api")
        let s = Projects.shortName("nyo-next-fleet-consolidation-frontend", max: 22)
        #expect(s.count == 22)
        #expect(s.hasPrefix("nyo-next-f") && s.hasSuffix("frontend") && s.contains("…"))
    }
}

struct GraphLayoutTests {
    private func sessions(_ projects: [String]) -> [Session] {
        projects.enumerated().map { i, p in
            var s = Session(id: "s\(i)", pid: Int32(i), cwd: "/Users/me/Projects/\(p)", title: "s\(i)",
                            status: i == 0 ? .needs : .working, since: Date(), tty: nil)
            s.project = "/Users/me/Projects/\(p)"
            return s
        }
    }

    private func tree(_ projects: [String]) -> ProjectTree {
        Workspaces.tree(sessions(projects), home: "/Users/me")
    }

    private func rect(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    static let setups: [[String]] = [
        ["fleet", "fleet", "fleet", "fleet", "hub"],
        ["shop-web", "docs", "api", "shop-web", "docs", "infra"],
        ["api", "api", "web", "web", "docs", "docs", "infra", "infra"],
        ["a", "a", "b", "c", "d", "e", "f", "g", "h", "b", "a", "a"],
        // In workspaces: acme and globex, and one project on its own.
        ["acme/acme-api", "acme/acme-api", "acme/acme-app", "globex/portal", "globex/web", "globex/web", "dotfiles", "acme/logbook"],
    ]

    /// Nothing overlaps, everything is inside the graph, and at its starting scale the graph fits
    /// the stage or (bigger than that at minScale) is meant to be panned.
    @Test(arguments: setups)
    func everythingFitsWithoutOverlapping(_ projects: [String]) {
        let t = tree(projects)
        let ids = t.workspaces.map(\.id) + t.repos.map(\.id)
        let stages = [CGSize(width: 1800, height: 900), CGSize(width: 1200, height: 652), CGSize(width: 820, height: 652),
                      CGSize(width: 600, height: 512), CGSize(width: 440, height: 652), CGSize(width: 320, height: 300)]
        for collapsed in [Set<String>(), [ids[0]], Set(ids)] {
            let items = GraphItem.items(t, collapsed: collapsed)
            for st in stages {
                let lay = GraphLayout(items: items, stage: CGRect(origin: .zero, size: st))
                let bounds = CGRect(origin: .zero, size: lay.size)
                var boxes = [lay.avatarBox]
                var shown = 0
                func visit(_ item: GraphItem) {
                    guard let p = lay.node(item.id) else { Issue.record("no place for node \(item.id)"); return }
                    boxes.append(rect(p, GraphLayout.nodeW, GraphLayout.nodeH))
                    for id in item.cards {
                        if let c = lay.card(id) { boxes.append(rect(c, GraphLayout.cardW, GraphLayout.cardH)); shown += 1 }
                        else { Issue.record("no place for \(id)") }
                    }
                    item.children.forEach(visit)
                }
                items.forEach(visit)
                for (i, b) in boxes.enumerated() {
                    #expect(bounds.insetBy(dx: -0.5, dy: -0.5).contains(b), "box \(i) outside the graph at \(st)")
                    for o in boxes[(i + 1)...] { #expect(!b.intersects(o), "overlap at \(st)") }
                }
                let room = CGSize(width: st.width - 2 * GraphLayout.margin, height: st.height - 2 * GraphLayout.margin)
                if lay.scrolls {
                    #expect(lay.scale >= GraphLayout.minScale - 0.001 || lay.mode == .stacked)
                } else {
                    #expect(lay.size.width * lay.scale <= room.width + 0.5, "too wide at \(st)")
                    #expect(lay.size.height * lay.scale <= room.height + 0.5, "too tall at \(st)")
                }
                #expect(lay.fitScale <= lay.scale + 0.001)
                // A line to every node beside the avatar (stacked: to every node below another), and to every card.
                func nodes(_ i: GraphItem) -> Int { 1 + i.children.map(nodes).reduce(0, +) }
                let all = items.map(nodes).reduce(0, +)
                #expect(lay.edges.count == shown + (lay.mode == .stacked ? all - items.count : all), "edges at \(st)")
            }
        }
    }

    @Test func wideStagesPutProjectsOnBothSides() {
        let t = tree(["fleet", "fleet", "fleet", "fleet", "hub"])
        let items = GraphItem.items(t, collapsed: [])
        let wide = GraphLayout(items: items, stage: CGRect(x: 0, y: 0, width: 1800, height: 900))
        #expect(wide.twoSided && wide.scale == 1)
        #expect(wide.node(items[0].id)!.x > wide.avatar.x && wide.node(items[1].id)!.x < wide.avatar.x)
        // Narrower: everything on the right of the avatar, still full size.
        let narrow = GraphLayout(items: items, stage: CGRect(x: 380, y: 0, width: 820, height: 652))
        #expect(!narrow.twoSided && narrow.scale == 1)
        #expect(narrow.node(items[0].id)!.x > narrow.avatar.x && narrow.node(items[1].id)!.x > narrow.avatar.x)
        // Task list and session detail both open in a 1200 pt window: stacked, readable, panning if need be.
        let tight = GraphLayout(items: items, stage: CGRect(x: 380, y: 0, width: 440, height: 652))
        #expect(tight.mode == .stacked && tight.scale >= GraphLayout.minScale)
    }

    @Test func eachProjectsSessionsStackBesideItsNode() throws {
        let t = tree(["api", "web", "api", "web", "docs"])
        let lay = GraphLayout(items: GraphItem.items(t, collapsed: []), stage: CGRect(x: 0, y: 0, width: 820, height: 652))
        for g in t.repos {
            let ys = try g.sessions.map { try #require(lay.card($0.id)).y }
            #expect(ys == ys.sorted())
            #expect(abs((ys.first! + ys.last!) / 2 - lay.node(g.id)!.y) < 0.5)
        }
    }

    @Test func workspacesSitBetweenTheAvatarAndTheirProjects() throws {
        let t = tree(["acme/acme-api", "acme/acme-app", "globex/web", "globex/web"])
        let lay = GraphLayout(items: GraphItem.items(t, collapsed: []), stage: CGRect(x: 0, y: 0, width: 1400, height: 900))
        #expect(lay.columns == 2)
        for w in t.workspaces {
            let wx = try #require(lay.node(w.id)).x
            for g in w.repos { #expect(try #require(lay.node(g.id)).x > wx) }
        }
    }

    @Test func aFoldedWorkspaceKeepsWhatNeedsYou() {
        let t = tree(["acme/acme-api", "acme/acme-app", "acme/acme-api", "globex/web"])
        let acme = t.workspaces.first { $0.name == "acme" }!
        let items = GraphItem.items(t, collapsed: [acme.id])
        let folded = items.first { $0.id == acme.id }!
        #expect(folded.children.isEmpty)
        #expect(folded.cards == ["s0"]) // the one that needs you
        let lay = GraphLayout(items: items, stage: CGRect(x: 0, y: 0, width: 1400, height: 900))
        #expect(lay.card("s0") != nil && lay.card("s1") == nil)
    }
}

struct AutoLayoutTests {
    @Test func smallStaysSmall() {
        #expect(StageMode.auto(sessions: 3, repos: 2, topLevel: 2) == .orbit)
        #expect(StageMode.auto(sessions: 6, repos: 4, topLevel: 3) == .orbit)
        #expect(StageMode.auto(sessions: 7, repos: 4, topLevel: 3) == .graph)
        // Many sessions in one project: nothing to group, the orbit.
        #expect(StageMode.auto(sessions: 9, repos: 1, topLevel: 1) == .orbit)
        #expect(StageMode.auto(sessions: 16, repos: 3, topLevel: 2) == .sidebar)
        #expect(StageMode.auto(sessions: 12, repos: 10, topLevel: 4) == .sidebar)
    }
}

struct SwitcherTests {
    private func session(_ id: String, _ project: String, _ title: String, _ status: SessionStatus = .working) -> Session {
        var s = Session(id: id, pid: 1, cwd: project, title: title, status: status, since: Date(), tty: nil)
        s.project = project
        return s
    }

    private var sample: ([Session], ProjectTree) {
        var list = [session("a", "/Users/me/Projects/acme/acme-api", "Release PR", .needs),
                    session("b", "/Users/me/Projects/acme/acme-app", "Push notifications iOS"),
                    session("c", "/Users/me/Projects/globex/portal", "Login with Azure AD")]
        let t = Workspaces.tree(list, known: ["/Users/me/Projects/acme/acme-logbook"], home: "/Users/me")
        for i in list.indices { list[i].place = t.place(ofRepo: list[i].project) }
        return (list, t)
    }

    @Test func everyWordHasToMatch() {
        let (list, t) = sample
        let r = Switcher.results("acme app", sessions: list, tree: t)
        #expect(r.first?.kind == .session && r.first?.target == "b")
        #expect(r.contains { $0.kind == .repo && $0.title == "acme › app" })
        #expect(!r.contains { $0.kind == .session && $0.target == "c" })
        // What to do with the best project.
        #expect(r.contains { $0.kind == .start } && r.contains { $0.kind == .terminal })
    }

    @Test func projectsWithoutSessionsAreFoundToo() {
        let (list, t) = sample
        let r = Switcher.results("logbook", sessions: list, tree: t)
        #expect(r.first?.kind == .repo && r.first?.title == "acme › logbook")
    }

    @Test func withNothingTypedWhatWantsALook() {
        let (list, t) = sample
        let r = Switcher.results("", sessions: list, tree: t)
        #expect(r.filter { $0.kind == .session }.map(\.target) == ["a"])
        #expect(!r.contains { $0.kind == .start })
    }
}

struct GhosttyTabTests {
    @Test func aNewTabGoesToTheWindowItsWorkspaceHolds() {
        let placed: [(window: String, key: String)] = [("w1", "acme"), ("w1", "acme"), ("w1", "globex"), ("w2", "globex"), ("w2", "globex")]
        #expect(GhosttyTabs.window(for: "acme", among: placed) == "w1")
        #expect(GhosttyTabs.window(for: "globex", among: placed) == "w2")
        // No window is mostly lab: a new window.
        #expect(GhosttyTabs.window(for: "lab", among: placed) == nil)
        // One mixed window, evenly split: neither owns it.
        #expect(GhosttyTabs.window(for: "acme", among: [("w1", "acme"), ("w1", "globex")]) == nil)
    }

    @Test func tabNamesSayProjectAndSession() {
        var s = Session(id: "a", pid: 1, cwd: "/x", title: "✳ Release PR 05.11.", status: .working, since: Date(), tty: nil)
        // The tab keeps the icon its own title has.
        #expect(GhosttyTabs.name(s, project: "api", ownTitle: "◐ Release PR 05.11.") == "◐ api · Release PR 05.11.")
        s.status = .done
        #expect(GhosttyTabs.name(s, project: "api", ownTitle: "✅ Release PR 05.11.") == "✅ api · Release PR 05.11.")
        // Without one: an icon for its status. Needing you always shows.
        #expect(GhosttyTabs.name(s, project: "api", ownTitle: "Release PR") == "✅ api · Release PR 05.11.")
        s.status = .needs
        #expect(GhosttyTabs.name(s, project: "api", ownTitle: "✳ Release PR 05.11.") == "❗ api · Release PR 05.11.")
        s.status = .working
        s.title = String(repeating: "x", count: 60)
        #expect(GhosttyTabs.name(s, project: "api").count == "◐ api · ".count + 34)
    }

    @Test func spinnerFramesReadAsOneIcon() {
        #expect(GhosttyTabs.icon(ofTitle: "⠂ Working") == "◐")
        #expect(GhosttyTabs.icon(ofTitle: "⠐ Working") == "◐")
        #expect(GhosttyTabs.icon(ofTitle: "⏳ Waiting") == "⏳")
        #expect(GhosttyTabs.icon(ofTitle: "Release PR") == nil)
        #expect(GhosttyTabs.icon(ofTitle: "") == nil)
    }

    @Test func sortingKeepsOtherTabsAtTheEnd() {
        let keys = ["t3": "globex\u{1}web", "t1": "acme\u{1}api", "t4": "globex\u{1}portal"]
        #expect(GhosttyTabs.sorted(["t1", "t2", "t3", "t4"], keys: keys) == ["t1", "t4", "t3", "t2"])
    }
}

struct CanvasTests {
    @Test func contentThatFitsIsCentered() {
        let p = CanvasView.clamp(CGPoint(x: 500, y: -300), content: CGSize(width: 400, height: 300),
                                 stage: CGSize(width: 1000, height: 800), margin: 24)
        #expect(p == CGPoint(x: 300, y: 250))
    }

    @Test func bigContentStopsAtTheMargins() {
        let stage = CGSize(width: 1000, height: 800), content = CGSize(width: 2000, height: 1600)
        #expect(CanvasView.clamp(CGPoint(x: 100, y: 100), content: content, stage: stage, margin: 24) == CGPoint(x: 24, y: 24))
        #expect(CanvasView.clamp(CGPoint(x: -5000, y: -5000), content: content, stage: stage, margin: 24) == CGPoint(x: -1024, y: -824))
    }

    @Test func zoomKeepsThePointUnderTheMouse() {
        let pan = CGPoint(x: 10, y: 20), anchor = CGPoint(x: 300, y: 200)
        let p = CanvasView.zoomed(pan, from: 1, to: 2, at: anchor)
        // The content point under the anchor: (anchor - pan) / scale, the same before and after.
        #expect((anchor.x - pan.x) / 1 == (anchor.x - p.x) / 2)
        #expect((anchor.y - pan.y) / 1 == (anchor.y - p.y) / 2)
    }
}
