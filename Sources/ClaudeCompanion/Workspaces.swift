import Foundation

/// A project without an open session, for the sidebar and the ⌘K switcher.
struct IdleRepo: Identifiable, Equatable, Hashable {
    let root: String
    var name: String
    var id: String { root }
}

/// A folder of projects, the way Finder shows them: ~/Projects/acme holds acme-api, acme-app, …
struct Workspace: Identifiable, Equatable {
    /// The folder's path.
    let id: String
    var name: String
    /// Its projects with sessions, the one with the most urgent session first.
    var repos: [ProjectGroup]
    /// Its other projects (no session open), by name.
    var idle: [IdleRepo]

    var sessions: [Session] { repos.flatMap(\.sessions) }
    var repoCount: Int { repos.count + idle.count }
}

/// Every project the companion knows of, by workspace. Workspaces and projects come in the order
/// of the sessions they hold (the orbit's order: what needs you first).
struct ProjectTree: Equatable {
    var workspaces: [Workspace] = []
    /// Projects with sessions that sit directly in a code folder (like ~/Projects/dotfiles).
    var loose: [ProjectGroup] = []
    var looseIdle: [IdleRepo] = []

    var hasWorkspaces: Bool { !workspaces.isEmpty }
    /// Every project with a session.
    var repos: [ProjectGroup] { workspaces.flatMap(\.repos) + loose }
    /// Workspaces and loose projects with sessions: the first level of the graph.
    var topLevelCount: Int { workspaces.filter { !$0.repos.isEmpty }.count + loose.count }
    var allIdle: [IdleRepo] { workspaces.flatMap(\.idle) + looseIdle }

    func workspace(_ id: String?) -> Workspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    func repo(_ id: String?) -> ProjectGroup? {
        guard let id else { return nil }
        return repos.first { $0.id == id }
    }

    /// The workspace a project (with or without sessions) is in.
    func workspace(ofRepo root: String) -> Workspace? {
        workspaces.first { w in w.repos.contains { $0.id == root } || w.idle.contains { $0.root == root } }
    }

    static func normalized(_ p: String) -> String {
        ((p as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// Where a project sits: "acme › api", or just its name outside a workspace ("acme/" for the
    /// workspace's own folder).
    func place(ofRepo root: String) -> String {
        for w in workspaces {
            if let r = w.repos.first(where: { $0.id == root }) {
                return ProjectTree.normalized(r.root) == w.id ? w.name + "/" : w.name + " › " + r.name
            }
            if let r = w.idle.first(where: { $0.root == root }) { return w.name + " › " + r.name }
        }
        if let r = loose.first(where: { $0.id == root }) { return r.name }
        if let r = looseIdle.first(where: { $0.root == root }) { return r.name }
        return Projects.name(root)
    }
}

enum Workspaces {
    /// Folders that hold projects or workspaces but aren't a workspace themselves.
    static let containerNames: Set<String> = [
        "documents", "dokumente", "desktop", "schreibtisch", "developer", "code", "coding", "projects", "projekte",
        "repos", "repositories", "src", "source", "sources", "dev", "development", "git", "github", "gitlab",
        "workspace", "workspaces", "work", "arbeit", "sites", "programming", "local",
    ]

    private static func norm(_ p: String) -> String {
        ((p as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func parent(_ p: String) -> String { (p as NSString).deletingLastPathComponent }

    /// The workspace folder a project belongs to, or nil when it sits directly in a code folder.
    ///
    /// Going down from the home folder (or `/` outside it), folders named like a code folder
    /// (Documents, Projects, Code, …) are passed through. The next folder is the workspace, unless
    /// no known project sits directly in it: then it only groups workspaces (~/Clients/acme/api)
    /// and the workspace is further down. A chosen `codeFolder` overrides all that: its child
    /// folders are the workspaces.
    /// - Parameter parents: the folders known projects sit in (`dirname` of each project root).
    static func folder(of root: String, parents: Set<String>, home: String = NSHomeDirectory(), codeFolder: String? = nil) -> String? {
        let path = norm(root)
        guard path.hasPrefix("/"), path != "/" else { return nil }
        let home = norm(home)
        if let cf = codeFolder.map(norm), path.hasPrefix(cf + "/") {
            let first = path.dropFirst(cf.count + 1).split(separator: "/").first.map(String.init) ?? ""
            let w = (cf as NSString).appendingPathComponent(first)
            return w == path ? nil : w
        }
        var start = path.hasPrefix(home + "/") ? home : "/"
        var rest = path.dropFirst(start == "/" ? 1 : start.count + 1).split(separator: "/").map(String.init)
        // Pass through folders named like a code folder.
        while rest.count > 1, containerNames.contains(rest[0].lowercased()) {
            start = (start as NSString).appendingPathComponent(rest[0])
            rest.removeFirst()
        }
        while rest.count > 1 {
            let w = (start as NSString).appendingPathComponent(rest[0])
            // A project directly inside: this is the workspace.
            if parents.contains(w) || rest.count == 2 { return w }
            start = w
            rest.removeFirst()
        }
        return nil
    }

    /// A project's name in its workspace: "acme-api" in acme reads "api".
    static func shortName(_ name: String, workspace: String, dropPrefix: Bool) -> String {
        guard dropPrefix else { return name }
        let ws = workspace.lowercased()
        for sep in ["-", "_", ".", " "] where name.lowercased().hasPrefix(ws + sep) {
            let rest = String(name.dropFirst(ws.count + sep.count))
            if !rest.isEmpty { return rest }
        }
        return name
    }

    /// Whether a project root is a real project worth listing without a session: a folder that
    /// is a git repo, not a temporary or app-support folder.
    static func listable(_ root: String) -> Bool {
        let p = norm(root)
        for bad in ["/private/", "/tmp/", "/var/folders/", Paths.support.path] where p.hasPrefix(bad) { return false }
        if p.contains("/Library/Application Support/") || p.contains("/.claude/") { return false }
        return FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent(".git"))
    }

    /// The git repos directly inside `folder` (for a workspace's projects without a session).
    /// A linked worktree checked out beside its repo (acme-api-1234) is that repo, not another.
    static func repos(in folder: String, home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.map { (folder as NSString).appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git")) }
            .filter { norm(Projects.root(of: $0, home: home)) == norm($0) }
    }

    /// Sessions by workspace and project. `known` are project roots without sessions (to list
    /// them too). With `enabled` off, or when everything would land in one workspace, projects
    /// aren't put in workspaces at all.
    static func tree(_ sessions: [Session], known: [String] = [], enabled: Bool = true, dropPrefix: Bool = true,
                     home: String = NSHomeDirectory(), codeFolder: String? = nil) -> ProjectTree {
        let groups = Projects.groups(sessions)
        let live = Set(groups.map { norm($0.root) })
        var seen = Set<String>()
        let idleRoots = known.filter { r in
            let n = norm(r)
            return !live.contains(n) && seen.insert(n).inserted
        }
        guard enabled else { return flat(groups, idleRoots) }

        let parents = projectParents(groups.map(\.root) + idleRoots)
        func ws(_ root: String) -> String? { folder(of: root, parents: parents, home: home, codeFolder: codeFolder) }
        var order: [String] = []
        var byWS: [String: (repos: [ProjectGroup], idle: [IdleRepo])] = [:]
        var loose: [ProjectGroup] = []
        var looseIdle: [IdleRepo] = []
        for var g in groups {
            if let w = ws(g.root) {
                if byWS[w] == nil { order.append(w); byWS[w] = ([], []) }
                g.workspace = w
                byWS[w]!.repos.append(g)
            } else {
                loose.append(g)
            }
        }
        for r in idleRoots {
            if let w = ws(r) {
                if byWS[w] == nil { order.append(w); byWS[w] = ([], []) }
                byWS[w]!.idle.append(IdleRepo(root: r, name: ""))
            } else {
                looseIdle.append(IdleRepo(root: r, name: ""))
            }
        }
        // A session in a workspace's own folder (not in one of its projects) belongs to it.
        for (i, g) in loose.enumerated().reversed() where byWS[norm(g.root)] != nil {
            var g = g
            g.workspace = norm(g.root)
            byWS[norm(g.root)]!.repos.insert(g, at: 0)
            loose.remove(at: i)
        }
        // One workspace and nothing beside it says nothing: show the projects on their own.
        if order.count <= 1 && loose.isEmpty && looseIdle.isEmpty { return flat(groups, idleRoots) }

        // Workspaces in the order of their most urgent session; ones without sessions after, by name.
        let rank = Dictionary(groups.enumerated().map { (norm($0.element.root), $0.offset) }, uniquingKeysWith: min)
        func firstRank(_ w: String) -> Int { byWS[w]!.repos.compactMap { rank[norm($0.root)] }.min() ?? Int.max }
        order.sort { a, b in
            let ra = firstRank(a), rb = firstRank(b)
            if ra != rb { return ra < rb }
            return (a as NSString).lastPathComponent.localizedCaseInsensitiveCompare((b as NSString).lastPathComponent) == .orderedAscending
        }
        var workspaces: [Workspace] = order.map { w in
            Workspace(id: w, name: (w as NSString).lastPathComponent, repos: byWS[w]!.repos, idle: byWS[w]!.idle)
        }
        // Names: a workspace's projects without its prefix; the parent folder when two names clash.
        let wsBase = workspaces.map(\.name)
        for i in workspaces.indices {
            if wsBase.enumerated().contains(where: { $0.offset != i && $0.element == wsBase[i] }) {
                let up = (parent(workspaces[i].id) as NSString).lastPathComponent
                workspaces[i].name = up.isEmpty || up == "/" ? wsBase[i] : "\(up)/\(wsBase[i])"
            }
            let w = workspaces[i]
            let wsName = (w.id as NSString).lastPathComponent
            func name(_ root: String) -> String {
                // Sessions in the workspace folder itself: "acme/".
                if norm(root) == w.id { return wsName + "/" }
                return shortName(Projects.name(root), workspace: wsName, dropPrefix: dropPrefix)
            }
            var names = w.repos.map { name($0.root) } + w.idle.map { name($0.root) }
            // Two projects that read the same: their path inside the workspace.
            let first = names
            for k in names.indices where first.enumerated().contains(where: { $0.offset != k && $0.element == first[k] }) {
                let root = k < w.repos.count ? w.repos[k].root : w.idle[k - w.repos.count].root
                names[k] = String(norm(root).dropFirst(w.id.count + 1))
            }
            for k in w.repos.indices { workspaces[i].repos[k].name = names[k] }
            for k in w.idle.indices { workspaces[i].idle[k].name = names[w.repos.count + k] }
            workspaces[i].idle.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        let looseNames = names(loose.map(\.root) + looseIdle.map(\.root))
        for k in loose.indices { loose[k].name = looseNames[k] }
        for k in looseIdle.indices { looseIdle[k].name = looseNames[loose.count + k] }
        looseIdle.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ProjectTree(workspaces: workspaces, loose: loose, looseIdle: looseIdle)
    }

    /// The folders projects sit in directly. A folder that holds other projects (a session
    /// started in ~/Clients/acme itself) is a folder of projects, not a project in ~/Clients.
    static func projectParents(_ roots: [String]) -> Set<String> {
        let all = Set(roots.map(norm))
        return Set(all.filter { r in !all.contains { $0.hasPrefix(r + "/") } }.map(parent))
    }

    /// No workspaces: every project on its own, named as `Projects.groups` names them.
    private static func flat(_ groups: [ProjectGroup], _ idle: [String]) -> ProjectTree {
        let n = names(groups.map(\.root) + idle)
        var loose = groups
        for k in loose.indices { loose[k].name = n[k]; loose[k].workspace = nil }
        let looseIdle = idle.enumerated().map { IdleRepo(root: $0.element, name: n[groups.count + $0.offset]) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ProjectTree(workspaces: [], loose: loose, looseIdle: looseIdle)
    }

    /// Folder names, with the parent folder where two clash.
    private static func names(_ roots: [String]) -> [String] {
        let base = roots.map { Projects.name($0) }
        return roots.indices.map { i in
            guard base.enumerated().contains(where: { $0.offset != i && $0.element == base[i] }) else { return base[i] }
            let up = (parent(roots[i]) as NSString).lastPathComponent
            return up.isEmpty || up == "/" ? base[i] : "\(up)/\(base[i])"
        }
    }

    /// Project roots worth listing, from the folders Claude Code ran in, plus the other repos in
    /// the workspaces those reveal. Reads the file system; run it off the main thread.
    static func discover(folders: [String], home: String = NSHomeDirectory(), codeFolder: String? = nil) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for f in folders {
            let r = Projects.root(of: f, home: home)
            if listable(r), seen.insert(norm(r)).inserted { roots.append(norm(r)) }
        }
        let parents = projectParents(roots)
        var wsFolders = Set(roots.compactMap { folder(of: $0, parents: parents, home: home, codeFolder: codeFolder) })
        // A session started in a folder of repos that isn't a repo itself (~/Clients/acme):
        // that folder is a workspace too.
        for f in folders {
            let n = norm(f)
            guard n != norm(home), !containerNames.contains((n as NSString).lastPathComponent.lowercased()) else { continue }
            if !listable(n), norm(Projects.root(of: n, home: home)) == n, repos(in: n, home: home).count >= 2 { wsFolders.insert(n) }
        }
        for w in wsFolders.sorted() {
            for r in repos(in: w, home: home) where seen.insert(norm(r)).inserted { roots.append(norm(r)) }
        }
        if let cf = codeFolder {
            // A chosen code folder: everything one or two levels down.
            for child in repos(in: cf, home: home) where seen.insert(norm(child)).inserted { roots.append(norm(child)) }
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: cf)) ?? [] where !name.hasPrefix(".") {
                for r in repos(in: (cf as NSString).appendingPathComponent(name), home: home) where seen.insert(norm(r)).inserted {
                    roots.append(norm(r))
                }
            }
        }
        return roots
    }
}
