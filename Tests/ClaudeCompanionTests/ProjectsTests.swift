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
    private func groups(_ projects: [String]) -> [ProjectGroup] {
        let list: [Session] = projects.enumerated().map { i, p in
            var s = Session(id: "s\(i)", pid: Int32(i), cwd: "/c/\(p)", title: "s\(i)",
                            status: i == 0 ? .needs : .working, since: Date(), tty: nil)
            s.project = "/c/\(p)"
            return s
        }
        return Projects.groups(list)
    }

    private func rect(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    static let setups: [[String]] = [
        ["fleet", "fleet", "fleet", "fleet", "hub"],
        ["shop-web", "docs", "api", "shop-web", "docs", "infra"],
        ["api", "api", "web", "web", "docs", "docs", "infra", "infra"],
        ["a", "a", "b", "c", "d", "e", "f", "g", "h", "b", "a", "a"],
    ]

    /// Nothing overlaps, everything is inside the graph, and the graph fits the stage, at the
    /// stage sizes the window allows (side panels open or not), with and without folded projects.
    @Test(arguments: setups)
    func everythingFitsWithoutOverlapping(_ projects: [String]) {
        let gs = groups(projects)
        let stages = [CGSize(width: 1800, height: 900), CGSize(width: 1200, height: 652), CGSize(width: 820, height: 652),
                      CGSize(width: 600, height: 512), CGSize(width: 440, height: 652), CGSize(width: 320, height: 300)]
        for collapsed in [Set<String>(), [gs[0].id], Set(gs.map(\.id))] {
            for st in stages {
                let lay = GraphLayout(groups: gs, collapsed: collapsed, stage: CGRect(origin: .zero, size: st))
                let bounds = CGRect(origin: .zero, size: lay.size)
                var boxes = [lay.avatarBox]
                for g in gs {
                    boxes.append(rect(lay.node(g.id), GraphLayout.nodeW, GraphLayout.nodeH))
                    for s in g.sessions {
                        if collapsed.contains(g.id) {
                            #expect(lay.card(s.id) == nil)
                        } else if let p = lay.card(s.id) {
                            boxes.append(rect(p, GraphLayout.cardW, GraphLayout.cardH))
                        } else {
                            Issue.record("no place for \(s.id)")
                        }
                    }
                }
                for (i, b) in boxes.enumerated() {
                    #expect(bounds.insetBy(dx: -0.5, dy: -0.5).contains(b), "box \(i) outside the graph at \(st)")
                    for o in boxes[(i + 1)...] { #expect(!b.intersects(o), "overlap at \(st)") }
                }
                // It fits the stage, or (stacked, at no less than minScale) fits its width and scrolls.
                let room = CGSize(width: st.width - 2 * GraphLayout.margin, height: st.height - 2 * GraphLayout.margin)
                #expect(lay.size.width * lay.scale <= room.width + 0.5, "too wide at \(st)")
                if lay.scrolls {
                    #expect(lay.mode == .stacked && lay.scale >= GraphLayout.minScale - 0.001)
                } else {
                    #expect(lay.size.height * lay.scale <= room.height + 0.5, "too tall at \(st)")
                }
                // Beside the avatar, nothing is shown smaller than minScale.
                if lay.mode != .stacked { #expect(lay.scale >= GraphLayout.minScale - 0.001) }
                // An edge to every project beside the avatar, and to every card shown.
                let shownCards = gs.filter { !collapsed.contains($0.id) }.reduce(0) { $0 + $1.sessions.count }
                #expect(lay.edges.count == shownCards + (lay.mode == .stacked ? 0 : gs.count))
            }
        }
    }

    @Test func wideStagesPutProjectsOnBothSides() {
        let gs = groups(["fleet", "fleet", "fleet", "fleet", "hub"])
        let wide = GraphLayout(groups: gs, collapsed: [], stage: CGRect(x: 0, y: 0, width: 1800, height: 900))
        #expect(wide.twoSided && wide.scale == 1)
        #expect(wide.node(gs[0].id).x > wide.avatar.x && wide.node(gs[1].id).x < wide.avatar.x)
        // Narrower: everything on the right of the avatar, still full size.
        let narrow = GraphLayout(groups: gs, collapsed: [], stage: CGRect(x: 380, y: 0, width: 820, height: 652))
        #expect(!narrow.twoSided && narrow.scale == 1)
        #expect(narrow.node(gs[0].id).x > narrow.avatar.x && narrow.node(gs[1].id).x > narrow.avatar.x)
        // Task list and session detail both open in a 1200 pt window: stacked, readable, scrolling if need be.
        let tight = GraphLayout(groups: gs, collapsed: [], stage: CGRect(x: 380, y: 0, width: 440, height: 652))
        #expect(tight.mode == .stacked && tight.scale >= GraphLayout.minScale)
    }

    @Test func eachProjectsSessionsStackBesideItsNode() throws {
        let gs = groups(["api", "web", "api", "web", "docs"])
        let lay = GraphLayout(groups: gs, collapsed: [], stage: CGRect(x: 0, y: 0, width: 820, height: 652))
        for g in gs {
            let ys = try g.sessions.map { try #require(lay.card($0.id)).y }
            #expect(ys == ys.sorted())
            #expect(abs((ys.first! + ys.last!) / 2 - lay.node(g.id).y) < 0.5)
        }
    }
}
