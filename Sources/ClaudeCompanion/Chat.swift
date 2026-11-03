import Foundation
import SwiftUI

// MARK: - What the chat shows

/// One tool call, folded into a "steps" row between Claude's messages.
struct ChatStep: Equatable {
    let id: String
    let tool: String
    /// "Editing MainView.swift", in English (translated when shown).
    let text: String
    /// The command, file, pattern or URL, for the expanded row.
    let detail: String?
    var failed = false
}

struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable { case you, claude, steps, notice, error }

    let id: String
    var kind: Kind
    var text: String
    var at: Date?
    var steps: [ChatStep] = []
    var images = 0
    /// Claude's text, split into Markdown blocks once, off the main thread.
    var blocks: [MDBlock] = []
    /// The API message the text belongs to; Claude Code writes each content block as its own line.
    var messageId: String?

    static func == (a: ChatItem, b: ChatItem) -> Bool {
        a.id == b.id && a.kind == b.kind && a.text == b.text && a.steps == b.steps && a.images == b.images
    }
}

/// A message typed in the companion that the transcript hasn't shown yet.
struct ChatOutgoing: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let at: Date
    var failed = false
}

// MARK: - Reading the transcript

/// Turns a session transcript into chat items. Reads the tail once, then only what was appended.
/// Used on one background queue only.
final class ChatTranscript: @unchecked Sendable {
    let url: URL
    /// How much of the end of the file the chat starts from; "Show earlier" makes it bigger.
    private(set) var window: UInt64
    private(set) var items: [ChatItem] = []
    /// Prompts typed while Claude was busy, waiting for their turn.
    private(set) var queued: [String] = []
    private(set) var hasEarlier = false
    private var offset: UInt64 = 0
    private var stepLocation: [String: (item: Int, step: Int)] = [:]
    /// The chat lays out every row (scrolling to the end is reliable that way), so it keeps the
    /// newest ones; "Show earlier" allows more.
    private var maxItems = 200
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(url: URL, window: UInt64 = 1_500_000) {
        self.url = url
        self.window = window
    }

    func showEarlier() {
        window *= 4
        maxItems *= 2
        reset()
    }

    private func reset() {
        items = []
        queued = []
        stepLocation = [:]
        offset = 0
        hasEarlier = false
    }

    /// Reads whatever was appended since last time. True when the chat changed.
    func update() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return false }
        if size < offset { reset() } // rewritten
        if size == offset, offset > 0 { return false }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        var first = false
        if offset == 0 {
            first = true
            offset = size > window ? size - window : 0
            hasEarlier = offset > 0
        }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return first }
        // Only whole lines: the last one may still be being written.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return first }
        let complete = data[data.startIndex...lastNewline]
        var lines = complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if first, hasEarlier, !lines.isEmpty { lines.removeFirst() } // cut in half by the window
        offset += UInt64(complete.count)

        let before = (items.count, items.last, queued)
        for line in lines where !Self.skippable(line) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            consume(obj)
        }
        // Tool output can fill megabytes with a handful of messages: reach further back until
        // there's something to read.
        if first, hasEarlier, items.count < 40, window < 40_000_000 {
            window *= 4
            reset()
            return update()
        }
        if items.count > maxItems {
            items.removeFirst(items.count - maxItems)
            hasEarlier = true
            reindexSteps()
        }
        return first || before.0 != items.count || before.1 != items.last || before.2 != queued
    }

    private static let bookkeeping = ["{\"type\":\"api-request", "{\"type\":\"file-history", "{\"type\":\"frame-link",
                                      "{\"type\":\"last-prompt", "{\"type\":\"ai-title"].map { Data($0.utf8) }
    private static let toolResult = Data("\"type\":\"tool_result\"".utf8)
    private static let isError = Data("\"is_error\":true".utf8)
    private static let denied = Data("\"toolDenialKind\"".utf8)

    /// Lines the chat never shows, found without parsing them: Claude Code's own bookkeeping,
    /// and big tool results that didn't fail (screenshots, long command output).
    private static func skippable(_ line: Data.SubSequence) -> Bool {
        let head = line.prefix(24)
        if bookkeeping.contains(where: { head.starts(with: $0) }) { return true }
        if line.count > 16_000, line.range(of: toolResult) != nil,
           line.range(of: isError) == nil, line.range(of: denied) == nil { return true }
        return false
    }

    // MARK: entries

    private func consume(_ o: [String: Any]) {
        guard let type = o["type"] as? String else { return }
        if o["isSidechain"] as? Bool == true { return }
        let id = o["uuid"] as? String ?? UUID().uuidString
        let at = (o["timestamp"] as? String).flatMap { iso.date(from: $0) }
        switch type {
        case "user":
            user(o, id: id, at: at)
        case "assistant":
            assistant(o, id: id, at: at)
        case "attachment":
            // A prompt typed while Claude was busy, handed to it mid-turn.
            guard let a = o["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
                  a["commandMode"] as? String == "prompt" else { return }
            let (text, images) = Self.promptParts(a["prompt"])
            if let t = Clean.chat(text) ?? (images > 0 ? "" : nil) {
                addYou(id: id, text: t, images: images, at: at)
            }
        case "queue-operation":
            switch o["operation"] as? String {
            case "enqueue":
                if let c = o["content"] as? String, let t = Clean.chat(c), !t.isEmpty { queued.append(t) }
            case "remove":
                if let c = o["content"] as? String, let t = Clean.chat(c),
                   let i = queued.firstIndex(of: t) { queued.remove(at: i) }
            case "dequeue":
                if !queued.isEmpty { queued.removeFirst() }
            default:
                break
            }
        case "system":
            if o["subtype"] as? String == "compact_boundary" {
                items.append(ChatItem(id: id, kind: .notice, text: "Conversation compacted", at: at))
            }
        default:
            break
        }
    }

    private func user(_ o: [String: Any], id: String, at: Date?) {
        if o["isMeta"] as? Bool == true || o["isCompactSummary"] as? Bool == true
            || o["isVisibleInTranscriptOnly"] as? Bool == true { return }
        guard let msg = o["message"] as? [String: Any] else { return }
        if let parts = msg["content"] as? [[String: Any]], parts.contains(where: { $0["type"] as? String == "tool_result" }) {
            // Results only matter when a step failed or was denied.
            for p in parts where p["type"] as? String == "tool_result" {
                guard let tid = p["tool_use_id"] as? String, let loc = stepLocation[tid] else { continue }
                if p["is_error"] as? Bool == true || o["toolDenialKind"] != nil,
                   loc.item < items.count, loc.step < items[loc.item].steps.count {
                    items[loc.item].steps[loc.step].failed = true
                }
            }
            return
        }
        let (raw, images) = Self.promptParts(msg["content"])
        if raw.hasPrefix("[Request interrupted by user") {
            items.append(ChatItem(id: id, kind: .notice, text: "Interrupted", at: at))
            return
        }
        guard let text = Clean.chat(raw) ?? (images > 0 ? "" : nil) else { return }
        if text.isEmpty, images == 0 { return }
        addYou(id: id, text: text, images: images, at: at)
    }

    private func addYou(id: String, text: String, images: Int, at: Date?) {
        if let i = queued.firstIndex(of: text) { queued.remove(at: i) }
        // /compact shows up once before the compaction and once after it.
        if text.hasPrefix("/"), let last = items.last(where: { $0.kind != .notice }), last.kind == .you, last.text == text { return }
        items.append(ChatItem(id: id, kind: .you, text: text, at: at, images: images))
    }

    private func assistant(_ o: [String: Any], id: String, at: Date?) {
        guard let msg = o["message"] as? [String: Any] else { return }
        let messageId = msg["id"] as? String
        guard let parts = msg["content"] as? [[String: Any]] else { return }
        if o["isApiErrorMessage"] as? Bool == true {
            let t = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            items.append(ChatItem(id: id, kind: .error, text: t.isEmpty ? "Error" : t, at: at))
            return
        }
        for (n, p) in parts.enumerated() {
            switch p["type"] as? String {
            case "text":
                guard let t = p["text"] as? String else { continue }
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != "No response requested." else { continue }
                if var last = items.last, last.kind == .claude, last.messageId != nil, last.messageId == messageId {
                    last.text += "\n\n" + trimmed
                    last.blocks = MD.blocks(last.text)
                    items[items.count - 1] = last
                } else {
                    var item = ChatItem(id: n == 0 ? id : "\(id)-\(n)", kind: .claude, text: trimmed, at: at)
                    item.blocks = MD.blocks(trimmed)
                    item.messageId = messageId
                    items.append(item)
                }
            case "tool_use":
                let name = p["name"] as? String ?? "tool"
                let input = p["input"] as? [String: Any] ?? [:]
                let sid = p["id"] as? String ?? UUID().uuidString
                let step = ChatStep(id: sid, tool: name, text: Activity.describe(name, input), detail: Self.detail(name, input))
                if var last = items.last, last.kind == .steps {
                    last.steps.append(step)
                    items[items.count - 1] = last
                } else {
                    items.append(ChatItem(id: "steps-\(sid)", kind: .steps, text: "", at: at, steps: [step]))
                }
                stepLocation[sid] = (items.count - 1, items[items.count - 1].steps.count - 1)
            default:
                break
            }
        }
    }

    private func reindexSteps() {
        stepLocation = [:]
        for (i, item) in items.enumerated() where item.kind == .steps {
            for (j, s) in item.steps.enumerated() { stepLocation[s.id] = (i, j) }
        }
    }

    /// The text and the number of images in a prompt's content (a string or a list of parts).
    static func promptParts(_ content: Any?) -> (String, Int) {
        if let s = content as? String { return (s, 0) }
        guard let parts = content as? [[String: Any]] else { return ("", 0) }
        var texts: [String] = []
        var images = 0
        for p in parts {
            switch p["type"] as? String {
            case "text":
                if let t = p["text"] as? String, !t.hasPrefix("[Image: original") { texts.append(t) }
            case "image":
                images += 1
            default:
                break
            }
        }
        return (texts.joined(separator: "\n"), images)
    }

    static func detail(_ name: String, _ input: [String: Any]) -> String? {
        func path(_ k: String) -> String? { (input[k] as? String).map { ($0 as NSString).abbreviatingWithTildeInPath } }
        switch name {
        case "Bash": return (input["command"] as? String).map { String($0.prefix(300)) }
        case "Read", "Edit", "MultiEdit", "Write": return path("file_path")
        case "NotebookEdit": return path("notebook_path")
        case "Grep", "Glob": return input["pattern"] as? String
        case "WebFetch": return input["url"] as? String
        case "WebSearch": return input["query"] as? String
        case "Agent", "Task": return (input["prompt"] as? String).map { String($0.prefix(200)) }
        case "Skill": return input["skill"] as? String
        default: return nil
        }
    }
}

extension Clean {
    /// A prompt as the chat shows it: your words, with Claude Code's wrappers taken out.
    /// Nil for things you didn't type (background task results, agent messages, caveats).
    static func chat(_ raw: String) -> String? {
        var s = raw
        if s.contains("<task-notification>") || s.contains("<agent-message") || s.hasPrefix("Caveat:")
            || s.hasPrefix("[Cross-session") || s.contains("<bash-stdout>") || s.contains("<bash-stderr>")
            || s.contains("<local-command-stdout>") || s.contains("<local-command-stderr>") { return nil }
        if let r = s.range(of: "<command-name>([^<]*)</command-name>", options: .regularExpression) {
            var name = String(s[r]).replacingOccurrences(of: "<command-name>", with: "").replacingOccurrences(of: "</command-name>", with: "")
            if !name.hasPrefix("/") { name = "/" + name }
            var args = ""
            if let a = s.range(of: "<command-args>([\\s\\S]*?)</command-args>", options: .regularExpression) {
                args = String(s[a]).replacingOccurrences(of: "<command-args>", with: "").replacingOccurrences(of: "</command-args>", with: "")
            }
            return (name + " " + args).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let r = s.range(of: "<bash-input>([\\s\\S]*?)</bash-input>", options: .regularExpression) {
            let cmd = String(s[r]).replacingOccurrences(of: "<bash-input>", with: "").replacingOccurrences(of: "</bash-input>", with: "")
            return "! " + cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        s = s.replacingOccurrences(of: "<pasted_content[^>]*>[\\s\\S]*?</pasted_content[^>]*>", with: "[Pasted text]", options: .regularExpression)
        for tag in ["system-reminder", "local-command-caveat"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        // Markers like <artifact-content-authored-by-others/>.
        s = s.replacingOccurrences(of: "<[a-zA-Z][a-zA-Z0-9_-]*[^<>]*/>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 6000 { s = String(s.prefix(6000)) + "…" }
        return s.isEmpty ? nil : s
    }

    /// For matching what was typed against what the transcript shows.
    static func matchKey(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .prefix(80).map(Character.init))
    }
}

// MARK: - The selected session's chat

/// The chat of the session open in the detail, kept up to date while the Chat tab shows it.
@MainActor
final class ChatFeed: ObservableObject {
    @Published private(set) var sessionId: String?
    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var queued: [String] = []
    @Published private(set) var hasEarlier = false
    /// False until the first read is done; then true even when there's no transcript yet.
    @Published private(set) var loaded = false
    @Published private(set) var outbox: [String: [ChatOutgoing]] = [:]
    /// What you were typing, per session. Not published: keystrokes shouldn't redraw the window.
    var drafts: [String: String] = [:]

    private let queue = DispatchQueue(label: "companion.chat", qos: .userInitiated)
    private var transcript: ChatTranscript?
    private var reading = false
    private var generation = 0

    /// Starts following a session's transcript (nil stops).
    func open(_ s: Session?) {
        guard s?.id != sessionId || transcript == nil else { return }
        generation += 1
        sessionId = s?.id
        items = []
        queued = []
        hasEarlier = false
        loaded = false
        transcript = nil
        guard let s else { return }
        if Demo.on {
            // COMPANION_DEMO_CHAT=<transcript.jsonl> shows a real transcript, for checking the layout.
            if let path = ProcessInfo.processInfo.environment["COMPANION_DEMO_CHAT"] {
                let t = ChatTranscript(url: URL(fileURLWithPath: path))
                _ = t.update()
                items = t.items
            } else {
                items = Demo.chat(s.id)
            }
            loaded = true
            return
        }
        let gen = generation
        let id = s.id, cwd = s.cwd
        reading = true
        queue.async {
            let t = TranscriptReader.url(sessionId: id, cwd: cwd).map { ChatTranscript(url: $0) }
            _ = t?.update()
            let snap = t.map { ($0.items, $0.queued, $0.hasEarlier) }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.reading = false
                self.transcript = t
                if let snap { self.apply(snap) }
                self.loaded = true
            }
        }
    }

    /// Picks up anything new. Cheap when nothing changed (one stat).
    func refresh() {
        guard !reading, let t = transcript else {
            // No transcript yet (a brand-new session): look again.
            if !reading, transcript == nil, let id = sessionId, !Demo.on, loaded { retryOpen(id) }
            return
        }
        reading = true
        let gen = generation
        queue.async {
            let changed = t.update()
            let snap = changed ? (t.items, t.queued, t.hasEarlier) : nil
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.reading = false
                if let snap { self.apply(snap) }
            }
        }
    }

    private var lastRetry = Date.distantPast
    private func retryOpen(_ id: String) {
        guard Date().timeIntervalSince(lastRetry) > 3 else { return }
        lastRetry = Date()
        let gen = generation
        reading = true
        // The cwd isn't needed: the lookup falls back to searching every project folder.
        queue.async {
            let t = TranscriptReader.url(sessionId: id, cwd: "").map { ChatTranscript(url: $0) }
            _ = t?.update()
            let snap = t.map { ($0.items, $0.queued, $0.hasEarlier) }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.reading = false
                self.transcript = t
                if let snap { self.apply(snap) }
            }
        }
    }

    func showEarlier() {
        guard let t = transcript, !reading else { return }
        reading = true
        let gen = generation
        queue.async {
            t.showEarlier()
            _ = t.update()
            let snap = (t.items, t.queued, t.hasEarlier)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.reading = false
                self.apply(snap)
            }
        }
    }

    private func apply(_ snap: ([ChatItem], [String], Bool)) {
        if items != snap.0 { items = snap.0 }
        if queued != snap.1 { queued = snap.1 }
        hasEarlier = snap.2
        reconcileOutbox()
    }

    // MARK: sending

    func sent(_ text: String, session id: String) {
        outbox[id, default: []].append(ChatOutgoing(text: text, at: Date()))
    }

    func failed(_ text: String, session id: String) {
        guard var list = outbox[id], let i = list.lastIndex(where: { $0.text == text && !$0.failed }) else { return }
        list[i].failed = true
        outbox[id] = list
    }

    func dismiss(_ out: ChatOutgoing, session id: String) {
        outbox[id]?.removeAll { $0.id == out.id }
    }

    /// Typed messages disappear from the outbox once the transcript shows them (sent or queued).
    private func reconcileOutbox() {
        guard let id = sessionId, var list = outbox[id], !list.isEmpty else { return }
        let shown = items.filter { $0.kind == .you }.suffix(30)
        let queuedKeys = Set(queued.map(Clean.matchKey))
        list.removeAll { out in
            if out.failed { return false }
            if Date().timeIntervalSince(out.at) > 600 { return true }
            let key = Clean.matchKey(out.text)
            if queuedKeys.contains(key) { return true }
            return shown.contains { item in
                guard let at = item.at, at >= out.at.addingTimeInterval(-5) else { return false }
                let k = Clean.matchKey(item.text)
                return k == key || k.hasPrefix(key) || key.hasPrefix(k) && !k.isEmpty
            }
        }
        outbox[id] = list.isEmpty ? nil : list
    }
}

// MARK: - Markdown, a block at a time

/// A block of Claude's Markdown: SwiftUI's Text does the inline part (bold, code, links),
/// these do the rest.
struct MDBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case bullet(indent: Int, marker: String)
        case quote
        case code(lang: String)
        case table(rows: [[AttributedString]])
        case rule
    }
    let id: Int
    let kind: Kind
    let text: AttributedString

    static func == (a: MDBlock, b: MDBlock) -> Bool { a.id == b.id && a.kind == b.kind && a.text == b.text }
}

enum MD {
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    static func blocks(_ text: String) -> [MDBlock] {
        var out: [MDBlock] = []
        var para: [String] = []
        var code: [String]?
        var codeLang = ""
        var table: [String] = []
        func add(_ kind: MDBlock.Kind, _ text: AttributedString) { out.append(MDBlock(id: out.count, kind: kind, text: text)) }
        func flushPara() {
            if !para.isEmpty { add(.paragraph, inline(para.joined(separator: "\n"))) }
            para = []
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            let rows: [[AttributedString]] = table.compactMap { line in
                var l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("|") { l.removeFirst() }
                if l.hasSuffix("|") { l.removeLast() }
                let cells = l.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }) { return nil }
                return cells.map(inline)
            }
            if !rows.isEmpty { add(.table(rows: rows), AttributedString()) }
            table = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") {
                    add(.code(lang: codeLang), AttributedString(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushPara(); flushTable()
                code = []
                codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.hasPrefix("|"), trimmed.count > 1 {
                flushPara()
                table.append(trimmed)
                continue
            }
            flushTable()
            if trimmed.isEmpty { flushPara(); continue }
            if let m = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
                flushPara()
                add(.heading(trimmed.distance(from: m.lowerBound, to: m.upperBound) - 1), inline(String(trimmed[m.upperBound...])))
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flushPara(); add(.rule, AttributedString()); continue }
            let indent = (line.prefix { $0 == " " }.count) / 2
            if let m = trimmed.range(of: "^([-*+]|\\d{1,3}[.)]) ", options: .regularExpression) {
                flushPara()
                var marker = String(trimmed[m]).trimmingCharacters(in: .whitespaces)
                if marker == "-" || marker == "*" || marker == "+" { marker = "•" }
                var rest = String(trimmed[m.upperBound...])
                if rest.hasPrefix("[ ] ") { marker = "☐"; rest.removeFirst(4) } else if rest.hasPrefix("[x] ") { marker = "☑"; rest.removeFirst(4) }
                add(.bullet(indent: min(indent, 4), marker: marker), inline(rest))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushPara()
                add(.quote, inline(String(trimmed.drop { $0 == ">" || $0 == " " })))
                continue
            }
            para.append(trimmed)
        }
        if let code { add(.code(lang: codeLang), AttributedString(code.joined(separator: "\n"))) }
        flushPara()
        flushTable()
        return out
    }
}
