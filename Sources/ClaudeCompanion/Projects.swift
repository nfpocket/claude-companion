import Foundation

/// The sessions that work in one project: a git repo, or the folder itself when it isn't in one.
struct ProjectGroup: Identifiable, Equatable {
    /// The repo's root (a worktree counts as its main repo), or the session's folder.
    let root: String
    var name: String
    var sessions: [Session]
    var id: String { root }
}

enum Projects {
    /// The project a session in `cwd` belongs to: the root of its git repo, with a worktree
    /// counted as the repo it was made from. A folder outside any repo is its own project.
    /// Only reads the file system (no `git` call), so it is cheap enough to run on every scan.
    static func root(of cwd: String, home: String = NSHomeDirectory()) -> String {
        guard !cwd.isEmpty else { return cwd }
        let path = (cwd as NSString).expandingTildeInPath
        // Claude Code's own worktrees live inside the repo they were made from.
        if let r = path.range(of: "/.claude/worktrees/") { return String(path[..<r.lowerBound]) }
        let fm = FileManager.default
        var dir = (path as NSString).standardizingPath
        let home = (home as NSString).standardizingPath
        while !dir.isEmpty && dir != "/" {
            // A repo in your home folder (dotfiles) doesn't make everything under it one project.
            if dir == home && dir != (path as NSString).standardizingPath { break }
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                if isDir.boolValue { return dir }
                return worktreeRepo(dotGitFile: dotGit, in: dir) ?? dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return cwd
    }

    /// For a `.git` file ("gitdir: …"): the main repo's root when this is a linked worktree;
    /// nil for a submodule, which is a project of its own.
    private static func worktreeRepo(dotGitFile: String, in dir: String) -> String? {
        guard let text = try? String(contentsOfFile: dotGitFile, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitDir.hasPrefix("/") { gitDir = (dir as NSString).appendingPathComponent(gitDir) }
        gitDir = (gitDir as NSString).standardizingPath
        // A worktree's git dir has a `commondir` file pointing at the repo's own git dir.
        let commonFile = (gitDir as NSString).appendingPathComponent("commondir")
        guard let common = try? String(contentsOfFile: commonFile, encoding: .utf8) else { return nil }
        var commonDir = common.trimmingCharacters(in: .whitespacesAndNewlines)
        if !commonDir.hasPrefix("/") { commonDir = (gitDir as NSString).appendingPathComponent(commonDir) }
        commonDir = (commonDir as NSString).standardizingPath
        // Usually <repo>/.git; a bare repo (<name>.git) stands for the project itself.
        if (commonDir as NSString).lastPathComponent == ".git" { return (commonDir as NSString).deletingLastPathComponent }
        return commonDir
    }

    /// Sessions by project, in the order they come (so with the orbit's order, the project
    /// with the most urgent session comes first, and the most urgent session first within it).
    static func groups(_ sessions: [Session]) -> [ProjectGroup] {
        var out: [ProjectGroup] = []
        var index: [String: Int] = [:]
        for s in sessions {
            let root = s.project.isEmpty ? s.cwd : s.project
            if let i = index[root] {
                out[i].sessions.append(s)
            } else {
                index[root] = out.count
                out.append(ProjectGroup(root: root, name: "", sessions: [s]))
            }
        }
        // Names: the folder's name, with its parent when two projects share one.
        let base = out.map { displayName($0.root, parent: false) }
        for i in out.indices {
            let clash = base.enumerated().contains { $0.offset != i && $0.element == base[i] }
            out[i].name = clash ? displayName(out[i].root, parent: true) : base[i]
        }
        return out
    }

    /// The groups to show, or nil when grouping wouldn't add anything: everything is in one
    /// project, or every project has only one session.
    static func grouping(_ sessions: [Session]) -> [ProjectGroup]? {
        let g = groups(sessions)
        guard g.count >= 2, g.contains(where: { $0.sessions.count >= 2 }) else { return nil }
        return g
    }

    /// Long names lose their middle: "nyo-next-fle…tion-frontend".
    static func shortName(_ name: String, max: Int) -> String {
        guard name.count > max, max > 2 else { return name }
        let head = (max - 1) / 2
        return name.prefix(head) + "…" + name.suffix(max - 1 - head)
    }

    /// A project's name on its own: its folder's name.
    static func name(_ root: String) -> String { displayName(root, parent: false) }

    private static func displayName(_ root: String, parent: Bool) -> String {
        let p = root as NSString
        var name = p.lastPathComponent
        if name.hasSuffix(".git"), name.count > 4 { name = String(name.dropLast(4)) }
        if name.isEmpty { return root.isEmpty ? "?" : root }
        guard parent else { return name }
        let up = (p.deletingLastPathComponent as NSString).lastPathComponent
        return up.isEmpty || up == "/" ? name : "\(up)/\(name)"
    }
}
