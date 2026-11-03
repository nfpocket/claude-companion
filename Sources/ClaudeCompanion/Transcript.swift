import Foundation
import Darwin

// MARK: - Process info

struct ProcInfo {
    let tty: String?
    let start: Date
}

/// Start time and controlling terminal of a live process, or nil when it is gone.
func procInfo(_ pid: Int32) -> ProcInfo? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    let start = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    let dev = info.kp_eproc.e_tdev
    var tty: String?
    if dev != -1, let name = devname(dev, mode_t(S_IFCHR)) {
        let s = String(cString: name)
        if s != "??" { tty = "/dev/" + s }
    }
    return ProcInfo(tty: tty, start: start)
}

// MARK: - Transcript reading

struct TranscriptInfo {
    var title: String?
    var lastPrompt: String?
    var lastPromptAt: Date?
    var lastAnswer: String?
    var activity: String?
}

/// Reads the tail of a session transcript (they grow to many MB) and caches by mtime.
final class TranscriptReader {
    private struct Entry { var mtime: Date; var size: UInt64; var info: TranscriptInfo }
    private var cache: [String: Entry] = [:]
    private var located: [String: URL] = [:]
    private var fullScanTitle: [String: String] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func info(sessionId: String, cwd: String) -> TranscriptInfo? {
        guard let url = locate(sessionId: sessionId, cwd: cwd),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        if let c = cache[sessionId], c.mtime == mtime, c.size == size { return c.info }
        var info = parseTail(url: url, size: size)
        if info.title == nil {
            if let t = fullScanTitle[sessionId] {
                info.title = t
            } else if let t = scanWholeFileForTitle(url: url) {
                fullScanTitle[sessionId] = t
                info.title = t
            }
        } else {
            fullScanTitle[sessionId] = info.title
        }
        cache[sessionId] = Entry(mtime: mtime, size: size, info: info)
        return info
    }

    func forget(except keep: Set<String>) {
        cache = cache.filter { keep.contains($0.key) }
        located = located.filter { keep.contains($0.key) }
    }

    private func locate(sessionId: String, cwd: String) -> URL? {
        if let u = located[sessionId], FileManager.default.fileExists(atPath: u.path) { return u }
        let u = Self.url(sessionId: sessionId, cwd: cwd)
        located[sessionId] = u
        return u
    }

    /// Where Claude Code keeps a session's transcript: projects/<cwd slug>/<id>.jsonl, or
    /// wherever the id turns up when the slug doesn't match.
    static func url(sessionId: String, cwd: String) -> URL? {
        let fm = FileManager.default
        let slug = String(cwd.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        let direct = Paths.projects.appendingPathComponent(slug).appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: direct.path) { return direct }
        if let dirs = try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil) {
            for d in dirs {
                let f = d.appendingPathComponent("\(sessionId).jsonl")
                if fm.fileExists(atPath: f.path) { return f }
            }
        }
        return nil
    }

    private func parseTail(url: URL, size: UInt64) -> TranscriptInfo {
        var info = TranscriptInfo()
        guard let fh = try? FileHandle(forReadingFrom: url) else { return info }
        defer { try? fh.close() }
        let window: UInt64 = 700_000
        let start = size > window ? size - window : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return info }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        var custom: String?
        var ai: String?
        var lastPromptEntry: String?
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "custom-title":
                if custom == nil { custom = obj["customTitle"] as? String }
            case "ai-title":
                if ai == nil { ai = obj["aiTitle"] as? String }
            case "last-prompt":
                if lastPromptEntry == nil, let p = obj["lastPrompt"] as? String { lastPromptEntry = Clean.prompt(p) }
            case "user":
                if info.lastPrompt == nil, obj["isMeta"] as? Bool != true, let p = promptText(obj) {
                    info.lastPrompt = p
                    if let ts = obj["timestamp"] as? String { info.lastPromptAt = iso.date(from: ts) }
                }
            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let content = msg["content"] as? [[String: Any]] else { continue }
                for part in content.reversed() {
                    let pt = part["type"] as? String
                    if pt == "text", info.lastAnswer == nil, let t = part["text"] as? String,
                       !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        info.lastAnswer = t
                    }
                    if pt == "tool_use", info.activity == nil, let name = part["name"] as? String {
                        info.activity = Activity.describe(name, part["input"] as? [String: Any] ?? [:])
                    }
                }
            default:
                break
            }
        }
        if info.lastPrompt == nil { info.lastPrompt = lastPromptEntry }
        info.title = (custom ?? ai).map { Clean.title($0) }
        return info
    }

    private func promptText(_ obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = msg["content"] as? String {
            text = s
        } else if let parts = msg["content"] as? [[String: Any]] {
            if parts.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        }
        guard let t = text.map(Clean.prompt), !t.isEmpty else { return nil }
        return t
    }

    /// Titles can be far back in a long transcript: find the last one anywhere in the file.
    private func scanWholeFileForTitle(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        for key in ["\"customTitle\":\"", "\"aiTitle\":\""] {
            guard let r = data.range(of: Data(key.utf8), options: .backwards) else { continue }
            var i = r.upperBound
            var escaped = false
            while i < data.endIndex {
                let b = data[i]
                if escaped { escaped = false } else if b == UInt8(ascii: "\\") { escaped = true } else if b == UInt8(ascii: "\"") { break }
                i += 1
            }
            let literal = Data([UInt8(ascii: "\"")]) + data[r.upperBound..<i] + Data([UInt8(ascii: "\"")])
            if let s = try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed) as? String {
                return Clean.title(s)
            }
        }
        return nil
    }
}

enum Clean {
    static func title(_ s: String) -> String {
        s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prompt(_ raw: String) -> String {
        var s = raw
        if s.contains("<task-notification>") || s.contains("<agent-message") || s.hasPrefix("Caveat:") { return "" }
        if let r = s.range(of: "<command-name>([^<]*)</command-name>", options: .regularExpression) {
            let name = s[r].replacingOccurrences(of: "<command-name>", with: "").replacingOccurrences(of: "</command-name>", with: "")
            var args = ""
            if let a = s.range(of: "<command-args>([^<]*)</command-args>", options: .regularExpression) {
                args = s[a].replacingOccurrences(of: "<command-args>", with: "").replacingOccurrences(of: "</command-args>", with: "")
            }
            return (name + " " + args).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for tag in ["system-reminder", "local-command-stdout", "local-command-stderr", "local-command-caveat", "pasted_content"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") { return "" }
        if s.count > 600 { s = String(s.prefix(600)) + "…" }
        return s
    }

    /// Markdown-free first sentences of an assistant message, for fallbacks.
    static func gist(_ text: String, limit: Int = 220) -> String {
        var s = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_`#>|]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count <= limit { return s }
        let cut = String(s.prefix(limit))
        if let dot = cut.range(of: ". ", options: .backwards), cut.distance(from: cut.startIndex, to: dot.lowerBound) > 60 {
            return String(cut[..<dot.lowerBound]) + "."
        }
        return cut + "…"
    }
}

enum Activity {
    static func describe(_ name: String, _ input: [String: Any]) -> String {
        func base(_ k: String) -> String? { (input[k] as? String).map { ($0 as NSString).lastPathComponent } }
        switch name {
        case "Edit", "MultiEdit": return "Editing " + (base("file_path") ?? "files")
        case "NotebookEdit": return "Editing " + (base("notebook_path") ?? "a notebook")
        case "Write": return "Writing " + (base("file_path") ?? "a file")
        case "Read": return "Reading " + (base("file_path") ?? "files")
        case "Bash":
            if let d = input["description"] as? String, !d.isEmpty { return d }
            let c = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return "Running " + String(c.prefix(48))
        case "Grep", "Glob": return "Searching the code"
        case "WebFetch", "WebSearch": return "Looking things up online"
        case "Agent", "Task": return (input["description"] as? String).map { "Subagent: " + $0 } ?? "Running a subagent"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList": return "Updating its task list"
        case "AskUserQuestion": return "Asking you a question"
        case "ExitPlanMode": return "Proposing a plan"
        case "Skill": return "Using the " + (input["skill"] as? String ?? "") + " skill"
        case "Monitor", "ScheduleWakeup": return "Waiting on something"
        default:
            if name.hasPrefix("mcp__") {
                let tool = name.components(separatedBy: "__").last ?? name
                return "Using " + tool.replacingOccurrences(of: "_", with: " ")
            }
            return "Using " + name
        }
    }
}
