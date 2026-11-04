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
    // `ClaudeCompanion --chat <transcript.jsonl>` prints what the Chat tab would show.
    if let i = args.firstIndex(of: "--chat"), i + 1 < args.count {
        let t = ChatTranscript(url: URL(fileURLWithPath: args[i + 1]))
        let start = Date()
        _ = t.update()
        print(String(format: "%d items in %.0f ms, earlier: %@, queued: %d", t.items.count,
                     Date().timeIntervalSince(start) * 1000, t.hasEarlier ? "yes" : "no", t.queued.count))
        for item in t.items.suffix(Int(args.dropFirst(i + 2).first ?? "") ?? 40) {
            switch item.kind {
            case .steps:
                let failed = item.steps.filter(\.failed).count
                print("  ⚙ \(item.steps.count) steps\(failed > 0 ? " (\(failed) failed)" : ""): " + item.steps.suffix(3).map(\.text).joined(separator: " | "))
            default:
                let text = item.text.prefix(110).replacingOccurrences(of: "\n", with: " ⏎ ")
                print("\(item.kind) [\(item.blocks.count)b\(item.images > 0 ? " \(item.images)img" : "")]: \(text)")
            }
        }
        exit(0)
    }
    // `ClaudeCompanion --chat-selftest <transcript.jsonl>`: reads the file as if it were being
    // written in chunks (cut mid-line) and checks the chat ends up the same as one full read.
    if let i = args.firstIndex(of: "--chat-selftest"), i + 1 < args.count,
       let data = FileManager.default.contents(atPath: args[i + 1]) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chat-selftest-\(getpid()).jsonl")
        let whole = ChatTranscript(url: URL(fileURLWithPath: args[i + 1]), window: UInt64.max / 8)
        _ = whole.update()
        let cuts = [data.count / 3, data.count / 2 + 7, data.count * 4 / 5 + 3, data.count]
        try? data.prefix(cuts[0]).write(to: tmp)
        let growing = ChatTranscript(url: tmp, window: UInt64.max / 8)
        _ = growing.update()
        for k in 1..<cuts.count {
            let h = try! FileHandle(forWritingTo: tmp)
            h.seekToEndOfFile()
            h.write(data[cuts[k - 1]..<cuts[k]])
            try? h.close()
            _ = growing.update()
        }
        try? FileManager.default.removeItem(at: tmp)
        func sig(_ t: ChatTranscript) -> [String] { t.items.map { "\($0.kind)|\($0.text)|\($0.steps.map { "\($0.text)\($0.failed)" })" } }
        let same = sig(whole) == sig(growing)
        print("whole: \(whole.items.count) items, in chunks: \(growing.items.count) items, same: \(same)")
        exit(same ? 0 : 1)
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
        print("     line: \(s.statusLine) | meta: \(s.metaLine) | tty: \(s.tty ?? "-") | project: \(Projects.name(s.project))")
        if let p = s.lastPrompt { print("     prompt: \(p.prefix(90).replacingOccurrences(of: "\n", with: " "))") }
        if let a = s.lastAnswer { print("     answer: \(a.prefix(90).replacingOccurrences(of: "\n", with: " "))") }
    }
    if let groups = Projects.grouping(sessions) {
        print("Grouped by project: " + groups.map { "\($0.name) (\($0.sessions.count))" }.joined(separator: ", "))
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
