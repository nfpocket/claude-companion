import Foundation
import Testing
@testable import ClaudeCompanion

struct WorkspaceFolderTests {
    let home = "/Users/me"

    private func ws(_ root: String, _ others: [String] = [], code: String? = nil) -> String? {
        Workspaces.folder(of: root, parents: Workspaces.projectParents([root] + others), home: home, codeFolder: code)
    }

    @Test func theFolderAboveTheRepoIsTheWorkspace() {
        #expect(ws("/Users/me/Projects/acme/acme-api") == "/Users/me/Projects/acme")
        #expect(ws("/Users/me/Projects/globex/portal") == "/Users/me/Projects/globex")
        // Code folders on the way down are passed through: Documents, then Projects.
        #expect(ws("/Users/me/Documents/Projects/acme/acme-app") == "/Users/me/Documents/Projects/acme")
        #expect(ws("/Users/me/Documents/CodeTests/claude-hub") == "/Users/me/Documents/CodeTests")
    }

    @Test func aRepoDirectlyInACodeFolderHasNoWorkspace() {
        #expect(ws("/Users/me/Projects/dotfiles") == nil)
        #expect(ws("/Users/me/dotfiles") == nil)
        #expect(ws("/Users/me/Documents/Projects/wyngman") == nil)
    }

    @Test func aFolderOfWorkspacesIsLookedThrough() {
        // ~/Clients only holds workspaces: the workspace is the folder below it.
        #expect(ws("/Users/me/Clients/acme/api", ["/Users/me/Clients/globex/web"]) == "/Users/me/Clients/acme")
        // A session in the workspace folder itself doesn't make ~/Clients a workspace.
        #expect(ws("/Users/me/Clients/acme/api", ["/Users/me/Clients/acme"]) == "/Users/me/Clients/acme")
        // A deeper repo stays in the workspace whose projects sit directly in it.
        #expect(ws("/Users/me/Projects/acme/tools/cli", ["/Users/me/Projects/acme/acme-api"]) == "/Users/me/Projects/acme")
    }

    @Test func aChosenCodeFolderDecides() {
        #expect(ws("/Users/me/Clients/acme/api", code: "/Users/me/Clients") == "/Users/me/Clients/acme")
        #expect(ws("/Users/me/Clients/solo", code: "/Users/me/Clients") == nil)
        #expect(ws("/Volumes/Work/acme/api", code: "/Users/me/Clients") == "/Volumes/Work/acme")
    }

    @Test func prefixesOfTheWorkspaceAreDropped() {
        #expect(Workspaces.shortName("acme-api", workspace: "acme", dropPrefix: true) == "api")
        #expect(Workspaces.shortName("acme_app", workspace: "ACME", dropPrefix: true) == "app")
        #expect(Workspaces.shortName("acme-web-fleet", workspace: "acme-web", dropPrefix: true) == "fleet")
        #expect(Workspaces.shortName("acme", workspace: "acme", dropPrefix: true) == "acme")
        #expect(Workspaces.shortName("acmeapi", workspace: "acme", dropPrefix: true) == "acmeapi")
        #expect(Workspaces.shortName("acme-api", workspace: "acme", dropPrefix: false) == "acme-api")
    }
}

struct ProjectTreeTests {
    let home = "/Users/me"

    private func session(_ id: String, _ project: String, _ status: SessionStatus = .working) -> Session {
        var s = Session(id: id, pid: 1, cwd: project, title: id, status: status, since: Date(), tty: nil)
        s.project = project
        return s
    }

    @Test func sessionsGoIntoWorkspacesAndProjects() {
        let list = [session("a", "/Users/me/Projects/globex/globex-portal", .needs),
                    session("b", "/Users/me/Projects/acme/acme-api"),
                    session("c", "/Users/me/Projects/acme/acme-app"),
                    session("d", "/Users/me/Projects/acme/acme-api"),
                    session("e", "/Users/me/Projects/dotfiles")]
        let t = Workspaces.tree(list, known: ["/Users/me/Projects/acme/acme-logbook", "/Users/me/Projects/oss/swift-format"], home: home)
        // In the order of their most urgent session; one without sessions last.
        #expect(t.workspaces.map(\.name) == ["globex", "acme", "oss"])
        #expect(t.workspaces[1].repos.map(\.name) == ["api", "app"])
        #expect(t.workspaces[1].repos[0].sessions.map(\.id) == ["b", "d"])
        #expect(t.workspaces[1].idle.map(\.name) == ["logbook"])
        #expect(t.workspaces[0].repos.map(\.name) == ["portal"])
        #expect(t.loose.map(\.name) == ["dotfiles"])
        #expect(t.place(ofRepo: "/Users/me/Projects/acme/acme-api") == "acme › api")
        #expect(t.place(ofRepo: "/Users/me/Projects/dotfiles") == "dotfiles")
        #expect(t.workspace(ofRepo: "/Users/me/Projects/acme/acme-logbook")?.name == "acme")
    }

    @Test func aSessionInTheWorkspaceFolderItselfBelongsToIt() {
        let t = Workspaces.tree([session("a", "/Users/me/Projects/acme"), session("b", "/Users/me/Projects/acme/acme-api"),
                                 session("c", "/Users/me/Projects/globex/web")], home: home)
        #expect(t.workspaces.map(\.name).sorted() == ["acme", "globex"])
        #expect(t.loose.isEmpty)
        #expect(t.workspace(ofRepo: "/Users/me/Projects/acme")?.repos.count == 2)
    }

    @Test func oneWorkspaceAloneIsNoWorkspace() {
        let t = Workspaces.tree([session("a", "/Users/me/Work/acme/api"), session("b", "/Users/me/Work/acme/web")], home: home)
        #expect(!t.hasWorkspaces)
        #expect(t.loose.map(\.name) == ["api", "web"])
    }

    @Test func switchedOffEverythingIsOnItsOwn() {
        let list = [session("a", "/Users/me/Projects/acme/acme-api"), session("b", "/Users/me/Projects/globex/web")]
        let t = Workspaces.tree(list, enabled: false, home: home)
        #expect(!t.hasWorkspaces)
        #expect(t.loose.map(\.name) == ["acme-api", "web"])
    }

    @Test func projectsThatReadTheSameShowTheirPath() {
        let list = [session("a", "/Users/me/Projects/acme/acme-api"), session("b", "/Users/me/Projects/acme/legacy/api"),
                    session("c", "/Users/me/Projects/globex/web")]
        let t = Workspaces.tree(list, home: home)
        #expect(t.workspace(ofRepo: "/Users/me/Projects/acme/acme-api")?.repos.map(\.name) == ["acme-api", "legacy/api"])
    }
}

struct WorkspaceFolderNodeTests {
    @Test func theWorkspaceFolderItselfGetsItsOwnNode() {
        func session(_ id: String, _ p: String) -> Session {
            var s = Session(id: id, pid: 1, cwd: p, title: id, status: .working, since: Date(), tty: nil)
            s.project = p
            return s
        }
        let t = Workspaces.tree([session("a", "/Users/me/Projects/acme"), session("b", "/Users/me/Projects/acme/acme-api"),
                                 session("c", "/Users/me/Projects/globex/web")], home: "/Users/me")
        let items = GraphItem.items(t, collapsed: [])
        let acme = items.first { $0.id == "/Users/me/Projects/acme" }!
        #expect(Set(acme.children.map(\.id)).count == 2)
        #expect(!acme.children.contains { $0.id == acme.id })
        #expect(t.place(ofRepo: "/Users/me/Projects/acme") == "acme/")
        let lay = GraphLayout(items: items, stage: CGRect(x: 0, y: 0, width: 1400, height: 900))
        #expect(lay.node(acme.id) != lay.node(acme.children[0].id))
    }
}
