import AppKit
import SwiftUI
import TaskTrackerCore

MainActor.assumeIsolated {
    // `ClaudeCompanion --render-icon out.png` draws the app icon (used by scripts/build-app.sh).
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
        renderIcon(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }
    Demo.prepareTaskData()
    if args.contains("--dump") {
        Task { @MainActor in
            await runDiagnostics(args)
            exit(0)
        }
        RunLoop.main.run()
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

@MainActor
func renderIcon(to url: URL) {
    let view = ZStack {
        RoundedRectangle(cornerRadius: 230, style: .continuous)
            .fill(Color(hex: 0x16171B))
            .frame(width: 1024 - 200, height: 1024 - 200)
        Circle()
            .stroke(Theme.accent.opacity(0.45), lineWidth: 10)
            .frame(width: 620, height: 620)
        Pebble(mode: .idle, t: 1, scale: 5.2)
        Spark()
            .fill(Theme.accentLight)
            .frame(width: 96, height: 96)
            .offset(x: 200, y: -215)
    }
    .frame(width: 1024, height: 1024)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let cg = renderer.cgImage else { return }
    let rep = NSBitmapImageRep(cgImage: cg)
    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
}

/// `ClaudeCompanion --dump [--route "what needs me"] [--summarize]`: prints what the app sees.
@MainActor
func runDiagnostics(_ args: [String]) async {
    let store = SessionStore()
    let sessions = store.scanOnce()
    let ghostty = Ghostty()
    let snap: GhosttySnapshot = await withCheckedContinuation { c in ghostty.snapshot { c.resume(returning: $0) } }
    print("Ghostty front tty: \(snap.frontTTY ?? "-"), terminals: \(snap.terms.count)")
    for s in sessions {
        let tab = s.tty.flatMap { snap.terms[$0]?.tabIndex }.map { "⌘\($0)" } ?? "  "
        print("\(tab) [\(s.status.rawValue)] [\(s.language.rawValue)] \(s.title)")
        print("     line: \(s.statusLine) | meta: \(s.metaLine) | tty: \(s.tty ?? "-")")
        if let p = s.lastPrompt { print("     prompt: \(p.prefix(90).replacingOccurrences(of: "\n", with: " "))") }
        if let a = s.lastAnswer { print("     answer: \(a.prefix(90).replacingOccurrences(of: "\n", with: " "))") }
    }
    let brain = Brain()
    print("claude: \(brain.claudePath ?? "not found")")
    let tasks = TaskStore(fileURL: TaskStore.defaultFileURL)
    let todos = tasks.openTodos
    let doing = todos.filter { $0.stage == .inProgress }.count
    print("Tasks: \(doing) in progress, \(todos.count - doing) todo, \(todos.filter { !$0.images.isEmpty }.count) with images")
    if let menu = try? MenuStore().read() {
        print("Menu: \(menu.prs.count) PRs, \(menu.openChecks) open checks, \(menu.openIdeas) open ideas")
    }
    if let i = args.firstIndex(of: "--route"), i + 1 < args.count {
        var withTabs = sessions
        for k in withTabs.indices { withTabs[k].tabIndex = withTabs[k].tty.flatMap { snap.terms[$0]?.tabIndex } }
        let start = Date()
        let folders = AppModel.scanFolders()
        // --after "user said|you replied|user said…" seeds the conversation before the command.
        var history: [(fromUser: Bool, text: String)] = []
        if let h = args.firstIndex(of: "--after"), h + 1 < args.count {
            for (k, part) in args[h + 1].components(separatedBy: "|").enumerated() { history.append((k % 2 == 0, part)) }
        }
        if let intent = await brain.route(args[i + 1], sessions: withTabs, folders: folders, history: history) {
            let target = withTabs.first { $0.id == intent.sessionId }?.title ?? "-"
            print(String(format: "route (%.1fs): %@ → %@ | prompt: %@ | folder: %@ | say: %@",
                         Date().timeIntervalSince(start), intent.action.rawValue, target, intent.prompt, intent.folder, intent.say))
        } else {
            print("route failed")
        }
    }
    let wanted = args.firstIndex(of: "--summarize").flatMap { $0 + 1 < args.count && !args[$0 + 1].hasPrefix("--") ? args[$0 + 1] : nil }
    if args.contains("--summarize"),
       let s = sessions.first(where: { wanted != nil && $0.title.localizedCaseInsensitiveContains(wanted!) })
            ?? sessions.first(where: { $0.status == .done }) ?? sessions.first {
        let start = Date()
        let text = await brain.summarize(s, language: s.language) ?? "(no summary)"
        print(String(format: "summary of \"%@\" (%.1fs): %@", s.title, Date().timeIntervalSince(start), text))
    }
}
