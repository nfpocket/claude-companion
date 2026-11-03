import Foundation

/// Polls what Claude Code already writes to disk and turns it into `Session`s.
///
/// Sources, per session:
///  - ~/.claude/sessions/<pid>.json        status busy / idle / shell (Claude Code)
///  - ~/.claude/companion/events/<id>.*    needs / clear / prompt / outcome (companion-hook.sh)
///  - ~/.claude/tab-status/<id>            done / failed (tab-outcome.sh, fallback)
///  - the transcript                       title, last prompt, last answer, current tool
final class SessionStore {
    var onUpdate: (([Session]) -> Void)?

    private let queue = DispatchQueue(label: "companion.store", qos: .utility)
    private let transcripts = TranscriptReader()
    private var timer: DispatchSourceTimer?
    private let procStartFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.5, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func refreshSoon() {
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.tick() }
    }

    /// One synchronous scan, for diagnostics.
    func scanOnce() -> [Session] { queue.sync { scan() } }

    private func tick() {
        let list = scan()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(list) }
    }

    // MARK: scanning

    private func scan() -> [Session] {
        if Demo.on { return Demo.sessions() }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil) else { return [] }
        var out: [Session] = []
        var ids = Set<String>()
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidNum = d["pid"] as? NSNumber,
                  let sid = d["sessionId"] as? String else { continue }
            if let kind = d["kind"] as? String, kind != "interactive" { continue }
            // Headless runs (`claude -p`, the SDK, and this app's own brain calls) aren't sessions you watch.
            if let entry = d["entrypoint"] as? String, entry.hasPrefix("sdk") { continue }
            if let cwd = d["cwd"] as? String, cwd.hasPrefix(Paths.support.path) { continue }
            let pid = pidNum.int32Value
            guard let proc = procInfo(pid) else { continue }
            // A stale file whose pid now belongs to another process.
            if let ps = d["procStart"] as? String, let started = parseProcStart(ps),
               abs(started.timeIntervalSince(proc.start)) > 3 { continue }
            guard !ids.contains(sid) else { continue }
            ids.insert(sid)
            out.append(build(sid: sid, pid: pid, json: d, tty: proc.tty))
        }
        transcripts.forget(except: ids)
        return out
    }

    private func build(sid: String, pid: Int32, json d: [String: Any], tty: String?) -> Session {
        let cwd = d["cwd"] as? String ?? ""
        let raw = d["status"] as? String
        let updated = msDate(d["statusUpdatedAt"]) ?? msDate(d["updatedAt"]) ?? Date()
        let updatedMs = updated.timeIntervalSince1970 * 1000
        let info = transcripts.info(sessionId: sid, cwd: cwd)

        var s = Session(id: sid, pid: pid, cwd: cwd,
                        title: info?.title ?? (d["name"] as? String) ?? "Claude Code",
                        status: .idle, since: updated, tty: tty)
        s.activity = info?.activity
        s.lastPrompt = info?.lastPrompt
        s.lastPromptAt = info?.lastPromptAt
        s.lastAnswer = info?.lastAnswer
        s.language = Lang.detect([info?.lastPrompt, info?.lastAnswer, info?.title])

        let ev = Events(sid: sid)
        let latestClear = max(ev.clearTs, ev.promptTs, ev.outcome?.ts ?? 0)

        if let needs = ev.needs, needs.ts > latestClear, needs.ts >= updatedMs - 2000 {
            s.status = .needs
            s.since = Date(timeIntervalSince1970: needs.ts / 1000)
            s.needsDetail = needs.describe()
        } else if let r = raw, !["busy", "idle", "shell"].contains(r) {
            // Claude Code reports something we don't know, e.g. a prompt waiting on you.
            s.status = .needs
            s.needsDetail = "Waiting for you"
        } else if raw == "busy" {
            s.status = .working
        } else if raw == "shell" {
            s.status = .shell
        } else {
            // Idle: did the last turn end, and how? Take the newest record from either hook.
            var best: (failed: Bool, at: Double, last: String?)?
            if let o = ev.outcome { best = (o.kind == "fail", o.ts, o.last) }
            if let (kind, at) = tabStatusOutcome(sid) {
                let ms = at.timeIntervalSince1970 * 1000
                if best == nil || ms > best!.at + 1500 { best = (kind == "failed", ms, best?.last) }
            }
            if let b = best {
                // After a prompt we know of, only an outcome newer than it counts (an Esc leaves none).
                // Before the hook saw any prompt, accept one from around the time the session went idle.
                let valid = ev.promptTs > 0 ? b.at > ev.promptTs : b.at >= updatedMs - 120_000
                if valid {
                    s.status = b.failed ? .failed : .done
                    s.outcomeAt = Date(timeIntervalSince1970: b.at / 1000)
                    s.since = s.outcomeAt!
                    if let last = b.last, !last.isEmpty, s.lastAnswer == nil { s.lastAnswer = last }
                }
            }
        }
        return s
    }

    private func tabStatusOutcome(_ sid: String) -> (String, Date)? {
        let url = Paths.outcomes.appendingPathComponent(sid)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let at = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), at)
    }

    private func parseProcStart(_ s: String) -> Date? {
        let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return procStartFormat.date(from: collapsed)
    }

    private func msDate(_ v: Any?) -> Date? {
        guard let n = v as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }
}

/// The files companion-hook.sh writes for one session. Timestamps are in ms.
private struct Events {
    struct Needs {
        var ts: Double
        var tool: String?
        var command: String?
        var filePath: String?
        var question: String?
        var message: String?

        func describe() -> String {
            switch tool {
            case "AskUserQuestion": return question.map { "Asks you: " + $0 } ?? "Has a question for you"
            case "ExitPlanMode": return "Has a plan for you to approve"
            case "Bash": return command.map { "Asks to run " + String($0.prefix(60)) } ?? "Asks to run a command"
            case "Edit", "MultiEdit", "Write", "NotebookEdit":
                return "Asks to edit " + (filePath.map { ($0 as NSString).lastPathComponent } ?? "a file")
            case .some(let t): return "Asks to use " + t
            case .none:
                if let m = message, !m.isEmpty { return m.replacingOccurrences(of: "Claude ", with: "") }
                return "Waiting for you"
            }
        }
    }

    struct Outcome { var ts: Double; var kind: String; var last: String? }

    var needs: Needs?
    var outcome: Outcome?
    var clearTs: Double = 0
    var promptTs: Double = 0
    var hasAny = false

    init(sid: String) {
        let dir = Paths.events
        if let d = Events.read(dir.appendingPathComponent("\(sid).needs.json")) {
            hasAny = true
            let input = d["input"] as? [String: Any] ?? [:]
            needs = Needs(ts: (d["ts"] as? NSNumber)?.doubleValue ?? 0,
                          tool: d["tool"] as? String,
                          command: input["command"] as? String,
                          filePath: input["file_path"] as? String,
                          question: input["question"] as? String,
                          message: d["message"] as? String)
        }
        if let d = Events.read(dir.appendingPathComponent("\(sid).outcome.json")) {
            hasAny = true
            outcome = Outcome(ts: (d["ts"] as? NSNumber)?.doubleValue ?? 0,
                              kind: d["kind"] as? String ?? "stop",
                              last: d["last"] as? String)
        }
        if let d = Events.read(dir.appendingPathComponent("\(sid).clear.json")) {
            hasAny = true
            clearTs = (d["ts"] as? NSNumber)?.doubleValue ?? 0
        }
        if let d = Events.read(dir.appendingPathComponent("\(sid).prompt.json")) {
            hasAny = true
            promptTs = (d["ts"] as? NSNumber)?.doubleValue ?? 0
        }
    }

    private static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
