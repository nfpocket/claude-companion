import Foundation

/// What the user asked for, as worked out from a transcript.
struct Intent {
    enum Action: String {
        case askNeeds = "ask_needs", summarizeAll = "summarize_all", summarizeOne = "summarize_one"
        case sendPrompt = "send_prompt", focus, stop, close, newSession = "new_session"
        case mute, unmute, onlyNeeds = "only_needs", allAnnouncements = "all_announcements"
        case setLanguage = "set_language", menu
        case `repeat`, help, cancel, unknown
    }
    var action: Action
    var sessionId: String?
    var prompt: String = ""
    var folder: String = ""
    var minutes: Int = 0
    var say: String = ""
    /// For set_language: "en", "de" or "auto".
    var language: String = ""
}

/// Small, fast thinking done by a headless Claude Code call (`claude -p` with Haiku),
/// so it runs on the user's existing Claude login: no extra API key.
/// Hooks, plugins and MCP servers are kept out so these calls never show up as sessions.
final class Brain {
    let claudePath: String?
    private let workDir: URL

    init() {
        claudePath = Brain.findClaude()
        workDir = Paths.support.appendingPathComponent("brain")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    var available: Bool { claudePath != nil }

    private static func findClaude() -> String? {
        let home = Paths.home.path
        let candidates = ["\(home)/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude", "\(home)/.claude/local/claude"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Runs one structured-output call and returns the parsed object.
    func ask(system: String, prompt: String, schema: String, timeout: TimeInterval = 40) async -> [String: Any]? {
        guard let claude = claudePath else { return nil }
        let dir = workDir
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: claude)
                p.arguments = ["-p", "--model", "haiku", "--effort", "low",
                               "--tools", "", "--no-session-persistence",
                               "--setting-sources", "project", "--strict-mcp-config",
                               "--output-format", "json", "--json-schema", schema,
                               "--system-prompt", system]
                p.currentDirectoryURL = dir
                var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "CLAUDECODE" }
                env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:\(Paths.home.path)/.local/bin"
                p.environment = env
                let input = Pipe(), output = Pipe()
                p.standardInput = input
                p.standardOutput = output
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                input.fileHandleForWriting.write(Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                cont.resume(returning: obj?["structured_output"] as? [String: Any])
            }
        }
    }

    // MARK: summaries

    func summarize(_ s: Session, language: Lang) async -> String? {
        let system = """
        You tell a busy developer, out loud, where one of their Claude Code sessions stands. \
        Write one or two short spoken sentences, at most 40 words, in plain \(language.name), \
        whatever language the session itself is in. \
        No markdown, no lists, no file paths unless one is the point, no code. \
        Talk about the work, not about "the assistant" or "Claude". Describe the session from the outside, \
        never as if you were it: no "I" or "me" for the session. \
        If it is waiting for them, say what it needs. If it finished, say what it did and anything left for them to do. \
        If it failed, say what went wrong. Never invent details that are not in the material.
        \(language == .de ? "Write in natural German and address the developer as „du“." : "")
        """
        var parts = [
            "Session title: \(s.title)",
            "Folder: \(s.folder)",
            "Status: \(s.status.label)",
        ]
        if let d = s.needsDetail { parts.append("Waiting on: \(d)") }
        if s.status == .working || s.status == .shell, let a = s.activity { parts.append("Doing right now: \(a)") }
        if let p = s.lastPrompt { parts.append("The user's last prompt:\n\(p.prefix(1500))") }
        if let a = s.lastAnswer { parts.append("The session's last message:\n\(a.prefix(5000))") }
        let schema = #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#
        let r = await ask(system: system, prompt: parts.joined(separator: "\n\n"), schema: schema, timeout: 45)
        let text = (r?["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    // MARK: understanding commands

    /// `history`: the last few exchanges (oldest first), so a follow-up like "the Outlook one"
    /// can finish an earlier request. `replyIn`: the language for "say", or nil to match the user.
    func route(_ transcript: String, sessions: [Session], folders: [String],
               history: [(fromUser: Bool, text: String)] = [], replyIn: Lang? = nil) async -> Intent? {
        let system = """
        You turn a spoken command into one action for a desktop app that watches the user's Claude Code \
        sessions (each runs in a Ghostty terminal tab). The transcript can be English or German and may contain \
        speech-recognition mistakes. Pick the session the user means by its title, topic, folder, or tab number. \
        "Number three", "tab 3", "die Drei" or "⌘3" mean the session whose Ghostty tab is 3, never the third \
        line of the list. Use the session key from the list (like "s2"); leave it empty if none fits.

        Actions:
        - ask_needs: what needs me / what is waiting on me
        - summarize_all: summarize / briefing / what's going on across all sessions
        - summarize_one: what did / where is one particular session (needs session)
        - send_prompt: tell / ask a session to do something (needs session; prompt = the instruction to type, \
          in the language the user spoke, phrased as a direct request to that session; do not translate it)
        - focus: open / show / go to a session's tab (needs session)
        - stop: stop / interrupt / cancel what a session is doing right now (needs session)
        - close: close / end / quit a session entirely (needs session)
        - new_session: start a new session (folder = absolute path chosen from the folder list, prompt = what to \
          start it with, may be empty)
        - mute: be quiet, optionally for some minutes (minutes, 0 = until told otherwise)
        - unmute: you can talk again
        - only_needs: only tell me when something needs me
        - all_announcements: tell me about everything again, including finished sessions
        - repeat: say that again
        - help: what can I say
        - menu: what can I check / test now, what's on the menu (checks and ideas agents left on their PRs)
        - set_language: speak German / sprich Englisch / match each session's language \
          (language = "de", "en" or "auto")
        - cancel: never mind / cancel
        - unknown: anything else; put a short, friendly spoken reply in "say" (e.g. ask which session they mean)

        If a required session or folder is ambiguous, use unknown and ask in "say". Keep "say" under 20 words.

        The transcript is often a follow-up to the recent conversation, for example the answer to a question \
        you just asked ("the Outlook one", "number two", "in claude-hub"). Then treat the earlier request and \
        the follow-up as one: keep the action, prompt and details from the earlier request and fill in what \
        was missing. Only ask again if it is still unclear.
        """
        var lines: [String] = ["Sessions:"]
        for (i, s) in sessions.enumerated() {
            var l = "s\(i + 1): \"\(s.title)\" — folder \(s.folder) — \(s.status.label)"
            if let t = s.tabIndex { l += " — Ghostty tab \(t)" }
            if let a = s.activity, s.status == .working { l += " — \(a)" }
            lines.append(l)
        }
        if sessions.isEmpty { lines.append("(none open)") }
        lines.append("")
        lines.append("Folders the user works in:")
        lines.append(contentsOf: folders.prefix(30).map { "- \($0)" })
        lines.append("")
        let recent = history.suffix(8)
        if !recent.isEmpty {
            lines.append("Recent conversation (oldest first):")
            for turn in recent { lines.append("\(turn.fromUser ? "User" : "You"): \"\(turn.text)\"") }
            lines.append("")
        }
        lines.append("Write \"say\" in " + (replyIn.map { $0.name } ?? "the language the user spoke") + ".")
        lines.append("Transcript: \"\(transcript)\"")

        let schema = #"""
        {"type":"object","properties":{
          "action":{"type":"string","enum":["ask_needs","summarize_all","summarize_one","send_prompt","focus","stop","close","new_session","mute","unmute","only_needs","all_announcements","set_language","menu","repeat","help","cancel","unknown"]},
          "session":{"type":"string"},
          "prompt":{"type":"string"},
          "folder":{"type":"string"},
          "minutes":{"type":"integer"},
          "say":{"type":"string"},
          "language":{"type":"string","enum":["","en","de","auto"]}},
         "required":["action","session","prompt","folder","minutes","say","language"]}
        """#
        guard let r = await ask(system: system, prompt: lines.joined(separator: "\n"), schema: schema, timeout: 30),
              let a = r["action"] as? String, let action = Intent.Action(rawValue: a) else { return nil }
        var intent = Intent(action: action)
        if let key = r["session"] as? String, key.hasPrefix("s"), let n = Int(key.dropFirst()), n >= 1, n <= sessions.count {
            intent.sessionId = sessions[n - 1].id
        }
        intent.prompt = (r["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        intent.folder = (r["folder"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        intent.minutes = (r["minutes"] as? NSNumber)?.intValue ?? 0
        intent.say = r["say"] as? String ?? ""
        intent.language = r["language"] as? String ?? ""
        return intent
    }
}
