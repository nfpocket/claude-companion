import SwiftUI
import AppKit
import ServiceManagement

enum AvatarMode { case idle, listening, thinking, speaking }

struct Caption: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let sessionIds: [String]
}

/// Something that changes a session, waiting a moment (or for a click) before it happens.
struct PendingAction: Identifiable {
    enum Kind { case send, stop, close, newSession }
    let id = UUID()
    let kind: Kind
    var sessionId: String?
    var prompt: String
    var folder: String
    var heard: String?
    /// Seconds until it runs on its own; nil waits for a click.
    var countdown: Double?
    var started = Date()
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: sessions
    @Published private(set) var sessions: [Session] = []
    @Published var selectedId: String?
    @Published private(set) var summaries: [String: String] = [:]
    @Published private(set) var summarizing: Set<String> = []

    // MARK: voice
    @Published private(set) var listening = false
    @Published private(set) var thinking = false
    @Published private(set) var speaking = false
    @Published private(set) var replyTarget: String?
    @Published private(set) var heard: String?
    @Published private(set) var heardAt: Date?
    @Published private(set) var captions: [Caption] = []
    @Published private(set) var captionIndex: Int?
    @Published var pending: PendingAction?

    // MARK: todos (from Task Tracker)
    @Published private(set) var todos: [Todo] = []
    @Published private(set) var todosAvailable = false
    @Published var showTodos: Bool { didSet { defaults.set(showTodos, forKey: "showTodos") } }
    let todoStore = TodoStore()
    /// Todos waiting for a freshly started session to be ready, by that session's tty.
    private var pendingPastes: [String: (text: String, since: Date)] = [:]

    // MARK: ui state
    @Published var showHelp = false
    /// Whether the orbit window / the pill can be seen right now (drives animation).
    @Published var mainVisible = true
    @Published var pillVisible = false
    @Published var pillExpanded = false
    @Published private(set) var toast: String?
    @Published private(set) var hotkeyOK = true
    @Published private(set) var micDenied = false
    @Published private(set) var hooksInstalled = true
    @Published private(set) var folders: [String] = []
    @Published private(set) var voices: [Voice] = []
    @Published private(set) var charsLeft: Int?
    @Published private(set) var usingSystemVoice = false

    // MARK: settings
    @Published var speakOnDone: Bool { didSet { defaults.set(speakOnDone, forKey: "speakOnDone") } }
    @Published var onlyNeeds: Bool { didSet { defaults.set(onlyNeeds, forKey: "onlyNeeds") } }
    @Published var mutedUntil: Date? { didSet { defaults.set(mutedUntil?.timeIntervalSince1970, forKey: "mutedUntil") } }
    @Published var voiceId: String {
        didSet {
            defaults.set(voiceId, forKey: "voiceId")
            speaker.voiceId = voiceId
        }
    }
    /// The language I speak in: matched to each session, or always one language.
    enum LanguageSetting: String, CaseIterable, Identifiable {
        case auto, en, de
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return ui("Match each session", "Wie die jeweilige Session")
            case .en: return ui("Always English", "Immer Englisch")
            case .de: return ui("Always German", "Immer Deutsch")
            }
        }
    }
    @Published var languageSetting: LanguageSetting {
        didSet {
            defaults.set(languageSetting.rawValue, forKey: "languageSetting")
            publish() // summaries follow the new language
        }
    }

    /// The language of the app's own interface (buttons, labels, messages).
    @Published var uiLanguage: Lang {
        didSet {
            defaults.set(uiLanguage.rawValue, forKey: "uiLanguage")
            UIText.lang = uiLanguage
            replyLang = uiLanguage
            onUILanguageChange?()
        }
    }
    /// Set by the app delegate: rebuilds the menu bar in the new language.
    var onUILanguageChange: (() -> Void)?

    /// The voice for German sessions and German replies.
    @Published var voiceIdDE: String {
        didSet {
            defaults.set(voiceIdDE, forKey: "voiceIdDE")
            speaker.voiceIdDE = voiceIdDE
        }
    }

    /// Set by the app delegate: brings the orbit window to the front.
    var onOpenWindow: (() -> Void)?

    // MARK: services
    let store = SessionStore()
    let ghostty = Ghostty()
    let el: ElevenLabs
    let speaker: Speaker
    let recorder = Recorder()
    let brain = Brain()
    let hotkey = HotKey()

    private let defaults = UserDefaults.standard
    private var raw: [Session] = []
    private var snap = GhosttySnapshot()
    private var seenAt: [String: Date] = [:]
    private var known: [String: SessionStatus] = [:]
    private var primed = false
    private var summaryKeys: [String: String] = [:]
    private var diskSummaries: [String: [String: String]] = [:]
    private var summaryQueue: [String] = []
    private var summaryWorker: Task<Void, Never>?
    private var lastSpoken: (text: String, lang: Lang)?
    /// The language you last spoke to me in; my own replies use it when the setting is automatic.
    private var replyLang: Lang = .en

    /// The last few things said between you and me, so follow-ups ("the Outlook one") make sense.
    private struct Turn { let fromUser: Bool; let text: String; let at: Date }
    private var dialog: [Turn] = []
    private var pendingTimer: Timer?
    private var timers: [Timer] = []
    private var toastId = UUID()
    private var lastQuotaCheck = Date.distantPast

    static let defaultVoice = "JBFqnCBsd6RMkjVDRZzb" // George (premade, English)
    static let defaultVoiceDE = "87AwpS6yC86wa2WglbsK" // Michael Danisch (German, in the account)

    init() {
        let el = ElevenLabs()
        self.el = el
        self.speaker = Speaker(el: el)
        speakOnDone = defaults.object(forKey: "speakOnDone") as? Bool ?? true
        showTodos = defaults.object(forKey: "showTodos") as? Bool ?? true
        onlyNeeds = defaults.object(forKey: "onlyNeeds") as? Bool ?? false
        if let t = defaults.object(forKey: "mutedUntil") as? Double { mutedUntil = Date(timeIntervalSince1970: t) }
        voiceId = defaults.string(forKey: "voiceId") ?? AppModel.defaultVoice
        voiceIdDE = defaults.string(forKey: "voiceIdDE") ?? AppModel.defaultVoiceDE
        languageSetting = LanguageSetting(rawValue: defaults.string(forKey: "languageSetting") ?? "") ?? .auto
        uiLanguage = Lang(rawValue: defaults.string(forKey: "uiLanguage") ?? "") ?? .en
        UIText.lang = uiLanguage
        replyLang = uiLanguage
        if let seen = defaults.dictionary(forKey: "seenAt") as? [String: Double] {
            seenAt = seen.mapValues { Date(timeIntervalSince1970: $0) }
        }
        loadSummaries()
        if Demo.on {
            // Screenshots show the defaults, never this Mac's settings or history.
            speakOnDone = true
            onlyNeeds = false
            mutedUntil = nil
            voiceId = AppModel.defaultVoice
            voiceIdDE = AppModel.defaultVoiceDE
            languageSetting = .auto
            uiLanguage = .en
            UIText.lang = .en
            seenAt = [:]
            diskSummaries = [:]
            showTodos = true
        }
    }

    // MARK: derived

    var avatar: AvatarMode {
        if listening { return .listening }
        if thinking { return .thinking }
        if speaking { return .speaking }
        return .idle
    }

    var selected: Session? { sessions.first { $0.id == selectedId } }

    /// The language to talk about a session in.
    func lang(for s: Session) -> Lang {
        switch languageSetting {
        case .auto: return s.language
        case .en: return .en
        case .de: return .de
        }
    }

    /// The language for my own replies.
    var replyLanguage: Lang {
        switch languageSetting {
        case .auto: return replyLang
        case .en: return .en
        case .de: return .de
        }
    }

    var isMuted: Bool {
        guard let m = mutedUntil else { return false }
        return m > Date()
    }

    var currentCaptionIds: [String]? {
        guard let i = captionIndex, captions.indices.contains(i) else { return nil }
        return captions[i].sessionIds
    }

    var voiceName: String {
        if usingSystemVoice || !el.isConfigured { return "Mac voice" }
        let en = voices.first { $0.id == voiceId }?.name ?? (voiceId == AppModel.defaultVoice ? "George" : "Custom")
        let de = voices.first { $0.id == voiceIdDE }?.name ?? (voiceIdDE == AppModel.defaultVoiceDE ? "Michael Danisch" : "Custom")
        func short(_ n: String) -> String { n.components(separatedBy: " - ").first ?? n }
        return "\(short(en)) / \(short(de)) (DE)"
    }

    /// Height the bottom overlays take, so the orbit can make room.
    var overlayHeight: CGFloat {
        if listening || thinking { return 160 }
        if let p = pending, p.kind != .newSession { return 190 }
        if !captions.isEmpty { return CGFloat(min(captions.count, 5)) * 30 + 96 }
        return 0
    }

    func session(_ id: String?) -> Session? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func voiceLevel() -> Float {
        listening ? recorder.level : speaker.level()
    }

    // MARK: start

    func start() {
        todoStore.onUpdate = { [weak self] list, available in
            self?.todos = list
            self?.todosAvailable = available
        }
        todoStore.start()
        if Demo.on {
            store.onUpdate = { [weak self] list in
                self?.raw = list
                self?.publish()
            }
            store.start()
            return
        }
        el.apiKey = Secrets.elevenLabsKey()
        speaker.voiceId = voiceId
        speaker.voiceIdDE = voiceIdDE
        if !el.isConfigured {
            useSystemVoice(true)
            flash(ui("No ElevenLabs key in the Keychain (item “elevenlabs”), so I’m using the Mac voice.", "Kein ElevenLabs-Schlüssel im Schlüsselbund (Eintrag „elevenlabs“), deshalb nutze ich die Mac-Stimme."))
        }
        speaker.onStart = { [weak self] u in self?.utteranceStarted(u) }
        speaker.onFinish = { [weak self] u in self?.utteranceFinished(u) }
        speaker.onIdle = { [weak self] in self?.speakerIdle() }
        speaker.onSpent = { [weak self] n in self?.spent(n) }
        speaker.onError = { [weak self] e in self?.speechFailed(e) }

        store.onUpdate = { [weak self] list in
            self?.raw = list
            self?.publish()
        }
        store.start()

        hotkey.onPress = { [weak self] in self?.pttDown() }
        hotkey.onRelease = { [weak self] in self?.pttUp() }
        hotkeyOK = hotkey.register()

        hooksInstalled = FileManager.default.fileExists(atPath: Paths.claude.appendingPathComponent("hooks/companion-hook.sh").path)

        if !Recorder.authorized {
            Recorder.requestAccess { [weak self] ok in self?.micDenied = !ok }
        }

        every(3) { $0.pollGhostty() }
        every(30) { model in
            model.objectWillChange.send() // relative times
            if let m = model.mutedUntil, m <= Date() { model.mutedUntil = nil }
        }
        every(600) { $0.loadFolders() }
        pollGhostty()
        loadFolders()
        refreshQuota()
        loadVoices()
    }

    private func every(_ seconds: TimeInterval, _ body: @escaping (AppModel) -> Void) {
        let t = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self { body(self) } }
        }
        timers.append(t)
    }

    // MARK: sessions

    private func publish() {
        var list = raw
        for i in list.indices {
            if let tty = list[i].tty, let t = snap.terms[tty] { list[i].tabIndex = t.tabIndex }
            if list[i].status == .done || list[i].status == .failed {
                let at = list[i].outcomeAt ?? list[i].since
                list[i].unseen = (seenAt[list[i].id] ?? .distantPast) < at
            }
        }
        list.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            let ta = a.tabIndex ?? 99, tb = b.tabIndex ?? 99
            if ta != tb { return ta < tb }
            return a.id < b.id
        }
        detectTransitions(list)
        if list != sessions { sessions = list }
        deliverPendingPastes()
        if let sel = selectedId, !list.contains(where: { $0.id == sel }) { selectedId = nil }
        scheduleSummaries(list)
    }

    private func pollGhostty() {
        ghostty.snapshot { [weak self] s in
            guard let self else { return }
            self.snap = s
            // Looking at a finished session's tab counts as having seen it.
            if Ghostty.isFrontmost, let tty = s.frontTTY,
               let sess = self.raw.first(where: { $0.tty == tty }),
               sess.status == .done || sess.status == .failed {
                let at = sess.outcomeAt ?? sess.since
                if (self.seenAt[sess.id] ?? .distantPast) < at { self.markSeen(sess.id, publish: false) }
            }
            self.publish()
        }
    }

    func markSeen(_ id: String, publish again: Bool = true) {
        seenAt[id] = Date()
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        seenAt = seenAt.filter { $0.value > cutoff }
        defaults.set(seenAt.mapValues { $0.timeIntervalSince1970 }, forKey: "seenAt")
        if again { publish() }
    }

    func select(_ id: String?) {
        selectedId = (selectedId == id) ? nil : id
        if let id { markSeen(id) }
    }

    private func detectTransitions(_ list: [Session]) {
        var needs: [Session] = [], done: [Session] = [], failed: [Session] = []
        for s in list {
            let old = known[s.id]
            if primed, old != s.status {
                switch s.status {
                case .needs: needs.append(s)
                case .done where old != nil: done.append(s)
                case .failed where old != nil: failed.append(s)
                default: break
                }
            }
            known[s.id] = s.status
        }
        let ids = Set(list.map(\.id))
        known = known.filter { ids.contains($0.key) }
        primed = true
        announce(needs: needs, done: done, failed: failed)
    }

    private func announce(needs: [Session], done: [Session], failed: [Session]) {
        guard !isMuted, !listening else { return }
        // Don't tell you about the tab you're looking at.
        let watching: (Session) -> Bool = { s in Ghostty.isFrontmost && s.tty != nil && s.tty == self.snap.frontTTY }
        let n = needs.filter { !watching($0) }
        let f = failed.filter { !watching($0) }
        let d = (speakOnDone && !onlyNeeds) ? done.filter { !watching($0) } : []
        guard !(n.isEmpty && f.isEmpty && d.isEmpty) else { return }
        if !n.isEmpty { NSSound(named: "Glass")?.play() }
        // Each session is announced in its own language, one utterance per language.
        for lang in [Lang.en, .de] {
            var lines: [String] = []
            let ln = n.filter { self.lang(for: $0) == lang }, lf = f.filter { self.lang(for: $0) == lang }
            let ld = d.filter { self.lang(for: $0) == lang }
            if !ln.isEmpty { lines.append(Phrase.needsYou(ln.map(\.spokenName), lang)) }
            if !lf.isEmpty { lines.append(Phrase.failed(lf.map(\.spokenName), lang)) }
            if !ld.isEmpty { lines.append(Phrase.done(ld.map(\.spokenName), lang)) }
            if !lines.isEmpty { say(lines.joined(separator: " "), tag: "announce", lang: lang) }
        }
    }

    // MARK: summaries

    private func summaryKey(_ s: Session) -> String {
        let t = Int((s.outcomeAt ?? s.since).timeIntervalSince1970)
        return "\(s.status.rawValue)|\(t)|\(s.lastAnswer?.count ?? 0)|\(s.activity ?? "")|\(lang(for: s).rawValue)"
    }

    private func scheduleSummaries(_ list: [Session]) {
        for s in list where s.status == .done || s.status == .failed || s.status == .needs {
            let key = summaryKey(s)
            if summaryKeys[s.id] == key || summaryQueue.contains(s.id) || summarizing.contains(s.id) { continue }
            if let cached = diskSummaries[s.id], cached["key"] == key, let text = cached["text"] {
                summaries[s.id] = text
                summaryKeys[s.id] = key
                continue
            }
            summaryQueue.append(s.id)
        }
        runSummaryWorker()
    }

    private func runSummaryWorker() {
        guard summaryWorker == nil, !summaryQueue.isEmpty, brain.available, !Demo.on else { return }
        summaryWorker = Task { [weak self] in
            while true {
                guard let self, !self.summaryQueue.isEmpty else { break }
                let id = self.summaryQueue.removeFirst()
                if let s = self.session(id) { _ = await self.makeSummary(s) }
            }
            self?.summaryWorker = nil
        }
    }

    /// The spoken "where it stands" for a session, generated once per state.
    @discardableResult
    func makeSummary(_ s: Session) async -> String {
        let key = summaryKey(s)
        if summaryKeys[s.id] == key, let t = summaries[s.id] { return t }
        summarizing.insert(s.id)
        let text = await brain.summarize(s, language: lang(for: s)) ?? fallbackSummary(s)
        summarizing.remove(s.id)
        summaries[s.id] = text
        summaryKeys[s.id] = key
        diskSummaries[s.id] = ["key": key, "text": text]
        saveSummaries()
        return text
    }

    func ensureSummary(_ id: String) async {
        guard let s = session(id) else { return }
        await makeSummary(s)
    }

    func hasFreshSummary(_ s: Session) -> Bool { summaryKeys[s.id] == summaryKey(s) && summaries[s.id] != nil }

    private func fallbackSummary(_ s: Session) -> String {
        let de = lang(for: s) == .de
        switch s.status {
        case .needs:
            return de ? "Sie " + Phrase.waitingReason(s.needsDetail, .de) + "."
                      : "It " + (s.needsDetail ?? "is waiting for you").lowercasedFirst + "."
        case .working, .shell:
            return de ? "Sie arbeitet noch." : "It is " + (s.activity ?? "working").lowercasedFirst + "."
        default:
            if let a = s.lastAnswer { return Clean.gist(a) }
            return s.statusLine + "."
        }
    }

    private var summariesFile: URL { Paths.support.appendingPathComponent("summaries.json") }

    private func loadSummaries() {
        guard let data = try? Data(contentsOf: summariesFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return }
        diskSummaries = obj
    }

    private func saveSummaries() {
        if diskSummaries.count > 200 { diskSummaries = diskSummaries.filter { k, _ in raw.contains { $0.id == k } } }
        if let data = try? JSONSerialization.data(withJSONObject: diskSummaries) { try? data.write(to: summariesFile) }
    }

    // MARK: speaking

    /// Speaks `text` in `lang`, or in the language you last spoke to me in.
    func say(_ text: String, tag: String? = nil, lang: Lang? = nil) {
        let l = lang ?? replyLanguage
        lastSpoken = (text, l)
        remember(text, fromUser: false)
        speaker.say(text, tag: tag, language: l)
    }

    private func remember(_ text: String, fromUser: Bool) {
        let now = Date()
        // A pause of three minutes starts a new conversation.
        if let last = dialog.last, now.timeIntervalSince(last.at) > 180 { dialog.removeAll() }
        dialog.append(Turn(fromUser: fromUser, text: String(text.prefix(400)), at: now))
        if dialog.count > 8 { dialog.removeFirst(dialog.count - 8) }
    }

    private var recentDialog: [(fromUser: Bool, text: String)] {
        guard let last = dialog.last, Date().timeIntervalSince(last.at) <= 180 else { return [] }
        return dialog.map { ($0.fromUser, $0.text) }
    }

    /// The English or German wording, matching the language you last spoke in.
    private func tr(_ en: String, _ de: String) -> String { replyLanguage == .de ? de : en }

    func stopSpeaking() {
        speaker.stopAll()
        captions = []
        captionIndex = nil
    }

    private func utteranceStarted(_ u: Speaker.Utterance) {
        speaking = true
        if let tag = u.tag, let i = captions.firstIndex(where: { $0.id.uuidString == tag }) {
            captionIndex = i
            for id in captions[i].sessionIds { markSeen(id, publish: false) }
            publish()
        } else {
            // Everything spoken is also shown, so it can be read when the sound is off.
            captions = [Caption(text: u.text, sessionIds: [])]
            captionIndex = 0
        }
    }

    private func utteranceFinished(_ u: Speaker.Utterance) {}

    private func speakerIdle() {
        speaking = false
        guard !captions.isEmpty else { return }
        let ids = captions.map(\.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.speaker.isBusy, self.captions.map(\.id) == ids else { return }
            self.captions = []
            self.captionIndex = nil
        }
    }

    private func spent(_ n: Int) {
        if let c = charsLeft { charsLeft = max(0, c - n) }
        if Date().timeIntervalSince(lastQuotaCheck) > 60 { refreshQuota() }
        if let c = charsLeft, c < 500, !usingSystemVoice {
            useSystemVoice(true)
            flash(ui("Only \(c) ElevenLabs characters left, so I switched to the Mac voice.", "Nur noch \(c) ElevenLabs-Zeichen übrig, deshalb nutze ich jetzt die Mac-Stimme."))
        }
    }

    private func speechFailed(_ error: Error) {
        if let e = error as? ElevenLabsError, e.isQuota || e.status == 401 {
            useSystemVoice(true)
        }
        flash(error.localizedDescription + ui(" Using the Mac voice.", " Ich nutze die Mac-Stimme."))
    }

    func useSystemVoice(_ on: Bool) {
        usingSystemVoice = on
        speaker.useSystemVoice = on
    }

    func refreshQuota() {
        guard el.isConfigured else { return }
        lastQuotaCheck = Date()
        Task {
            if let q = try? await el.quota() { charsLeft = max(0, q.limit - q.used) }
        }
    }

    private func loadVoices() {
        guard el.isConfigured else { return }
        Task {
            guard let v = try? await el.voices() else { return }
            voices = v
            if !v.contains(where: { $0.id == voiceIdDE }), let de = v.first(where: { $0.language == "de" }) {
                voiceIdDE = de.id
            }
        }
    }

    // MARK: briefings

    func briefing() {
        pending = nil
        stopSpeaking()
        Task { await runBriefing() }
    }

    private func runBriefing() async {
        let list = sessions
        let l = replyLanguage
        guard !list.isEmpty else { say(Phrase.noSessions(l)); return }
        let needs = list.filter { $0.status == .needs }
        let failed = list.filter { $0.status == .failed && $0.unseen }
        let done = list.filter { $0.status == .done && $0.unseen }
        let busy = list.filter { $0.status == .working || $0.status == .shell }
        let quiet = list.filter { ($0.status == .done || $0.status == .failed) && !$0.unseen }
        let featured = needs + failed + done

        if featured.contains(where: { !hasFreshSummary($0) }) { thinking = true }
        var texts: [String: String] = [:]
        await withTaskGroup(of: (String, String).self) { group in
            for s in featured {
                group.addTask { @MainActor in (s.id, await self.makeSummary(s)) }
            }
            for await (id, t) in group { texts[id] = t }
        }
        thinking = false

        // My own framing is in your language; each session's summary is in that session's language.
        var caps: [(Caption, Lang)] = []
        if !needs.isEmpty { caps.append((Caption(text: Phrase.thingsNeedYou(needs.count, l), sessionIds: needs.map(\.id)), l)) }
        if featured.isEmpty { caps.append((Caption(text: Phrase.nothingNeedsYou(l), sessionIds: []), l)) }
        for s in featured {
            caps.append((Caption(text: "\(s.spokenName). \(texts[s.id] ?? s.statusLine)", sessionIds: [s.id]), lang(for: s)))
        }
        if !busy.isEmpty {
            caps.append((Caption(text: Phrase.stillWorking(busy.map(\.spokenName), activity: busy[0].activity, l),
                                 sessionIds: busy.map(\.id)), l))
        }
        if !quiet.isEmpty && featured.isEmpty {
            let q = Array(quiet.prefix(4))
            caps.append((Caption(text: Phrase.finishedEarlier(q.map(\.spokenName), l), sessionIds: q.map(\.id)), l))
        }
        captions = caps.map(\.0)
        captionIndex = nil
        for (c, lang) in caps { say(c.text, tag: c.id.uuidString, lang: lang) }
    }

    func askNeeds() {
        stopSpeaking()
        let needs = sessions.filter { $0.status == .needs }
        let failed = sessions.filter { $0.status == .failed && $0.unseen }
        let busy = sessions.filter { $0.status == .working || $0.status == .shell }.count
        let l = replyLanguage
        guard !needs.isEmpty || !failed.isEmpty else {
            say(Phrase.nothingNeedsYou(l) + (busy > 0 ? " " + Phrase.stillWorking(count: busy, l) : ""))
            return
        }
        var parts = [Phrase.thingsNeedYou(needs.count + failed.count, l)]
        for s in needs { parts.append("\(s.spokenName): \(Phrase.waitingReason(s.needsDetail, l)).") }
        if !failed.isEmpty { parts.append(Phrase.failed(failed.map(\.spokenName), l)) }
        let c = Caption(text: parts.joined(separator: " "), sessionIds: (needs + failed).map(\.id))
        captions = [c]
        selectedId = needs.first?.id ?? failed.first?.id
        say(c.text, tag: c.id.uuidString)
    }

    func readAloud(_ s: Session) {
        stopSpeaking()
        Task {
            if !hasFreshSummary(s) { thinking = true }
            let t = await makeSummary(s)
            thinking = false
            let c = Caption(text: "\(s.spokenName). \(t)", sessionIds: [s.id])
            captions = [c]
            say(c.text, tag: c.id.uuidString, lang: lang(for: s))
        }
    }

    // MARK: push to talk

    func pttDown(target: String? = nil) {
        guard !listening else { return }
        if speaker.isBusy { stopSpeaking() }
        guard Recorder.authorized else {
            Recorder.requestAccess { [weak self] ok in
                self?.micDenied = !ok
                if !ok { self?.flash(ui("Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.", "Der Mikrofonzugriff ist aus. Schalte ihn in Systemeinstellungen › Datenschutz & Sicherheit › Mikrofon ein.")) }
            }
            return
        }
        do {
            try recorder.start()
            listening = true
            replyTarget = target
            heard = nil
        } catch {
            flash(ui("Microphone error: ", "Mikrofonfehler: ") + error.localizedDescription)
        }
    }

    func pttUp() {
        guard listening else { return }
        let pcm = recorder.stop()
        listening = false
        let target = replyTarget
        guard Double(pcm.count) / 32_000 >= 0.45 else { replyTarget = nil; return }
        guard el.isConfigured else {
            replyTarget = nil
            flash(ui("Voice input needs the ElevenLabs key in the Keychain (item “elevenlabs”).", "Spracheingabe braucht den ElevenLabs-Schlüssel im Schlüsselbund (Eintrag „elevenlabs“)."))
            return
        }
        thinking = true
        Task {
            do {
                let (text, code) = try await el.transcribe(pcm16k: pcm)
                replyLang = code != nil ? Lang.from(code: code) : Lang.detect([text])
                heard = text
                heardAt = Date()
                if text.isEmpty {
                    thinking = false
                    flash(ui("I didn’t catch anything.", "Ich habe nichts verstanden."))
                } else {
                    await handle(text, target: target)
                    thinking = false
                }
            } catch {
                thinking = false
                flash(ui("Couldn’t transcribe that: ", "Das konnte ich nicht transkribieren: ") + error.localizedDescription)
            }
            replyTarget = nil
        }
    }

    /// Acts on text as if it had been spoken (used by the "local.claude-companion.heard"
    /// notification, e.g. from Shortcuts or a script).
    func act(onText text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        heard = t
        heardAt = Date()
        replyLang = Lang.detect([t])
        thinking = true
        Task {
            await handle(t, target: nil)
            thinking = false
        }
    }

    /// Esc: back out of whatever is happening. Returns false when there was nothing to undo.
    func escape() -> Bool {
        if listening {
            _ = recorder.stop()
            listening = false
            replyTarget = nil
            return true
        }
        if pending != nil { cancelPending(); return true }
        if speaker.isBusy || !captions.isEmpty { stopSpeaking(); return true }
        if showHelp { showHelp = false; return true }
        if selectedId != nil { selectedId = nil; return true }
        if pillExpanded { pillExpanded = false; return true }
        return false
    }

    // MARK: understanding

    private func handle(_ text: String, target: String?) async {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        let history = recentDialog
        remember(text, fromUser: true)
        if let target {
            if Self.matches(t, Self.cancelPattern) { return }
            propose(.send, sessionId: target, prompt: text, heard: text)
            return
        }
        if let fast = fastIntent(t) {
            await execute(fast, heard: text)
            return
        }
        guard brain.available else { say(tr("I can’t reach Claude Code to work out what you mean.", "Ich erreiche Claude Code gerade nicht.")); return }
        let fixed: Lang? = languageSetting == .auto ? nil : replyLanguage
        guard let intent = await brain.route(text, sessions: sessions, folders: folders,
                                             history: history, replyIn: fixed) else {
            say(tr("Sorry, I didn’t get that.", "Das habe ich nicht verstanden."))
            return
        }
        await execute(intent, heard: text)
    }

    private static let cancelPattern = #"^(cancel|never ?mind|forget it|abbrechen|vergiss es|nein|no)$"#

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Common phrases that don't need a model to understand.
    private func fastIntent(_ t: String) -> Intent? {
        if Self.matches(t, Self.cancelPattern) { return Intent(action: .cancel) }
        if Self.matches(t, #"^(what|who|anything)( (else|now))? (needs|wants|is waiting (on|for)) (me|my attention)( right now| now)?$|^was braucht (mich|meine aufmerksamkeit)( gerade)?$"#) {
            return Intent(action: .askNeeds)
        }
        if Self.matches(t, #"^((please )?(summari[sz]e|give me (a|the) (summary|briefing|rundown))( (all|everything|it all|the sessions))?|briefing|status( update)?|what'?s going on|what is going on|was ist los|fass (alles )?zusammen|zusammenfassung)$"#) {
            return Intent(action: .summarizeAll)
        }
        if Self.matches(t, #"^(be quiet|quiet|shush|shut up|stop talking|ruhe|sei (mal )?still)$"#) {
            var i = Intent(action: .mute)
            i.minutes = 60
            return i
        }
        if Self.matches(t, #"^(repeat( that)?|say (that|it) again|again|nochmal|wiederhol(e|en)?( das)?)$"#) { return Intent(action: .repeat) }
        if Self.matches(t, #"^(help|what can i say|hilfe)$"#) { return Intent(action: .help) }
        if Self.matches(t, #"^((please )?speak german|(sprich|rede) (bitte )?deutsch|auf deutsch( bitte)?)$"#) {
            var i = Intent(action: .setLanguage); i.language = "de"; return i
        }
        if Self.matches(t, #"^((please )?speak english|(sprich|rede) (bitte )?englisch|in english( please)?|auf englisch( bitte)?)$"#) {
            var i = Intent(action: .setLanguage); i.language = "en"; return i
        }
        return nil
    }

    private func execute(_ intent: Intent, heard: String) async {
        let s = session(intent.sessionId)
        switch intent.action {
        case .askNeeds:
            askNeeds()
        case .summarizeAll:
            stopSpeaking()
            await runBriefing()
        case .summarizeOne:
            guard let s else { say(intent.say.isEmpty ? tr("Which session do you mean?", "Welche Session meinst du?") : intent.say); return }
            selectedId = s.id
            readAloud(s)
        case .sendPrompt:
            guard let s else { say(intent.say.isEmpty ? tr("Which session should I send that to?", "An welche Session soll das gehen?") : intent.say); return }
            guard !intent.prompt.isEmpty else { say(tr("What should I tell it?", "Was soll ich ihr sagen?")); return }
            propose(.send, sessionId: s.id, prompt: intent.prompt, heard: heard)
        case .focus:
            guard let s else { say(intent.say.isEmpty ? tr("Which session do you mean?", "Welche Session meinst du?") : intent.say); return }
            focus(s)
        case .stop:
            guard let s else { say(intent.say.isEmpty ? tr("Which session should I stop?", "Welche Session soll ich stoppen?") : intent.say); return }
            propose(.stop, sessionId: s.id, heard: heard)
        case .close:
            guard let s else { say(intent.say.isEmpty ? tr("Which session should I close?", "Welche Session soll ich schließen?") : intent.say); return }
            propose(.close, sessionId: s.id, heard: heard)
        case .newSession:
            let folder = resolveFolder(intent.folder)
            guard let folder else { say(intent.say.isEmpty ? tr("Which folder should it start in?", "In welchem Ordner soll sie starten?") : intent.say); return }
            propose(.newSession, prompt: intent.prompt, folder: folder, heard: heard)
        case .mute:
            stopSpeaking()
            mutedUntil = intent.minutes > 0 ? Date().addingTimeInterval(Double(intent.minutes) * 60) : .distantFuture
            flash(intent.minutes > 0
                  ? ui("Quiet for \(intent.minutes) min. Say “you can talk again” to undo.", "\(intent.minutes) Min. still. Sag „du kannst wieder reden“, um das aufzuheben.")
                  : ui("Quiet until you say “you can talk again”.", "Still, bis du „du kannst wieder reden“ sagst."))
        case .unmute:
            mutedUntil = nil
            onlyNeeds = false
            say(tr("I’m back.", "Ich bin wieder da."))
        case .onlyNeeds:
            onlyNeeds = true
            say(tr("Okay. I’ll only speak up when something needs you.", "Okay. Ich melde mich nur noch, wenn dich etwas braucht."))
        case .allAnnouncements:
            onlyNeeds = false
            speakOnDone = true
            say(tr("Okay. I’ll tell you when sessions finish, too.", "Okay. Ich sage dir auch wieder, wenn Sessions fertig sind."))
        case .repeat:
            if let l = lastSpoken { speaker.say(l.text, language: l.lang) } else { say(tr("I haven’t said anything yet.", "Ich habe noch nichts gesagt.")) }
        case .setLanguage:
            switch intent.language {
            case "de": languageSetting = .de
            case "en": languageSetting = .en
            case "auto": languageSetting = .auto
            default: say(tr("Which language: English or German?", "Welche Sprache: Deutsch oder Englisch?")); return
            }
            say(languageSetting == .auto
                ? tr("Okay. I’ll speak each session’s own language.", "Okay. Ich spreche jetzt die Sprache der jeweiligen Session.")
                : tr("Okay. I’ll speak English from now on.", "Okay. Ab jetzt spreche ich Deutsch."))
        case .help:
            showHelp = true
        case .cancel:
            if pending != nil { cancelPending(); flash(ui("Cancelled.", "Abgebrochen.")) }
        case .unknown:
            say(intent.say.isEmpty ? tr("Sorry, I didn’t get that.", "Das habe ich nicht verstanden.") : intent.say)
        }
    }

    private func resolveFolder(_ f: String) -> String? {
        guard !f.isEmpty else { return nil }
        let expanded = (f as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue { return expanded }
        return folders.first { ($0 as NSString).lastPathComponent.lowercased() == f.lowercased() }
    }

    // MARK: actions

    func focus(_ s: Session) {
        guard let tty = s.tty else { Ghostty.activate(); return }
        ghostty.focus(tty: tty)
        markSeen(s.id)
    }

    func focusTab(_ n: Int) {
        if let s = sessions.first(where: { $0.tabIndex == n }) { focus(s) }
    }

    func openNewSession() {
        let folder = selected?.cwd ?? folders.first ?? Paths.home.path
        pending = PendingAction(kind: .newSession, prompt: "", folder: folder, countdown: nil)
        pendingTimer?.invalidate()
    }

    func propose(_ kind: PendingAction.Kind, sessionId: String? = nil, prompt: String = "", folder: String = "", heard: String? = nil) {
        if kind == .send, let s = session(sessionId), s.status == .needs {
            say(tr("\(s.spokenName) is waiting on a prompt in its tab. Answer that first.", "\(s.spokenName) wartet in ihrem Tab auf eine Antwort. Beantworte die zuerst."))
            focus(s)
            return
        }
        let countdown: Double? = switch kind {
        case .close: nil
        case .stop: 2.5
        case .send, .newSession: 3
        }
        let p = PendingAction(kind: kind, sessionId: sessionId, prompt: prompt, folder: folder, heard: heard, countdown: countdown)
        pending = p
        pendingTimer?.invalidate()
        if let c = countdown {
            pendingTimer = Timer.scheduledTimer(withTimeInterval: c, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.pending?.id == p.id, self.pending?.countdown != nil else { return }
                    self.confirmPending()
                }
            }
        }
    }

    /// Editing a proposed action stops its countdown.
    func holdPending() {
        pendingTimer?.invalidate()
        if pending?.countdown != nil { pending?.countdown = nil }
    }

    func updatePending(prompt: String? = nil, folder: String? = nil) {
        holdPending()
        if let prompt { pending?.prompt = prompt }
        if let folder { pending?.folder = folder }
    }

    func cancelPending() {
        pendingTimer?.invalidate()
        pending = nil
    }

    func confirmPending() {
        guard let p = pending else { return }
        pendingTimer?.invalidate()
        pending = nil
        perform(p)
    }

    private func perform(_ p: PendingAction) {
        switch p.kind {
        case .newSession:
            let prompt = p.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let cmd = prompt.isEmpty ? "claude" : "claude " + Self.shellQuote(prompt)
            ghostty.newTab(cwd: p.folder, input: cmd)
            flash(ui("Starting a session in ", "Starte eine Session in ") + (p.folder as NSString).lastPathComponent)
            store.refreshSoon()
            return
        default:
            break
        }
        guard let s = session(p.sessionId), let tty = s.tty else { flash(ui("That session is gone.", "Diese Session gibt es nicht mehr.")); return }
        switch p.kind {
        case .send:
            ghostty.send(text: p.prompt, tty: tty)
            NSSound(named: "Tink")?.play()
            flash(ui("Sent to ", "Gesendet an ") + s.spokenName)
        case .stop:
            ghostty.sendKey("escape", tty: tty)
            flash(ui("Stopped ", "Gestoppt: ") + s.spokenName)
        case .close:
            ghostty.send(text: "/exit", tty: tty)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.ghostty.close(tty: tty) }
            flash(ui("Closing ", "Schließe ") + s.spokenName)
        case .newSession:
            break
        }
        store.refreshSoon()
    }

    // MARK: todos into sessions

    /// Puts a todo into a session's prompt without sending it, and brings its tab forward
    /// so it can be edited first.
    func paste(_ todo: Todo, into s: Session) {
        guard let tty = s.tty else { flash(ui("That session is gone.", "Diese Session gibt es nicht mehr.")); return }
        if s.status == .needs {
            flash(ui("\(s.spokenName) is waiting on a prompt in its tab. Answer that first.",
                     "\(s.spokenName) wartet in ihrem Tab auf eine Antwort. Beantworte die zuerst."))
            focus(s)
            return
        }
        ghostty.send(text: todo.pasteText, tty: tty, submit: false)
        focus(s)
        flash(ui("Pasted into \(s.spokenName). Edit it, then press Return to send.",
                 "In \(s.spokenName) eingefügt. Bearbeite es und drück dann Return zum Senden."))
    }

    /// Starts claude in a new Ghostty tab and puts the todo into its prompt once it's ready.
    func startSession(with todo: Todo, in folder: String) {
        let name = (folder as NSString).lastPathComponent
        ghostty.newTab(cwd: folder, input: "claude") { [weak self] tty in
            guard let self else { return }
            guard let tty else {
                self.copyToClipboard(todo.pasteText)
                self.flash(ui("Started claude in \(name). The todo is on the clipboard.",
                              "claude in \(name) gestartet. Das Todo liegt in der Zwischenablage."))
                return
            }
            self.pendingPastes[tty] = (todo.pasteText, Date())
            self.flash(ui("Starting a session in \(name). The todo goes in as soon as it’s ready.",
                          "Starte eine Session in \(name). Das Todo kommt rein, sobald sie bereit ist."))
            self.store.refreshSoon()
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A new session counts as ready once Claude Code has registered it.
    private func deliverPendingPastes() {
        for (tty, p) in Array(pendingPastes) {
            if raw.contains(where: { $0.tty == tty && ($0.status == .idle || $0.status == .working) }) {
                pendingPastes[tty] = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    self.ghostty.send(text: p.text, tty: tty, submit: false)
                    self.ghostty.focus(tty: tty)
                    self.flash(ui("The todo is in the new session. Edit it, then press Return to send.",
                                  "Das Todo steht in der neuen Session. Bearbeite es und drück dann Return zum Senden."))
                }
            } else if Date().timeIntervalSince(p.since) > 45 {
                // e.g. claude is still asking whether to trust the folder.
                pendingPastes[tty] = nil
                copyToClipboard(p.text)
                flash(ui("The session wasn’t ready in time, so the todo is on the clipboard.",
                         "Die Session war nicht rechtzeitig bereit, das Todo liegt in der Zwischenablage."))
            }
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: misc

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            flash(ui("Couldn’t change the login item: ", "Das Anmeldeobjekt ließ sich nicht ändern: ") + error.localizedDescription)
        }
        objectWillChange.send()
    }

    func flash(_ text: String) {
        let id = UUID()
        toastId = id
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.toastId == id else { return }
            self.toast = nil
        }
    }

    func loadFolders() {
        let current = raw.map(\.cwd)
        Task.detached(priority: .utility) {
            let found = AppModel.scanFolders()
            await MainActor.run {
                var seen = Set<String>()
                self.folders = (current + found).filter { !$0.isEmpty && seen.insert($0).inserted }
            }
        }
    }

    /// Folders you have run Claude Code in, most recent first, from the transcript store.
    nonisolated static func scanFolders() -> [String] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil) else { return [] }
        var found: [(String, Date)] = []
        for d in dirs {
            guard let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let dated = files.filter { $0.pathExtension == "jsonl" }.compactMap { f -> (URL, Date)? in
                guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (f, m)
            }
            guard let newest = dated.max(by: { $0.1 < $1.1 }),
                  let fh = try? FileHandle(forReadingFrom: newest.0) else { continue }
            // The first lines can hold big pasted images, so read on until a cwd shows up.
            var data = Data()
            var r: Range<Data.Index>?
            while r == nil, data.count < 4_000_000, let chunk = try? fh.read(upToCount: 262_144), !chunk.isEmpty {
                data.append(chunk)
                r = data.range(of: Data("\"cwd\":\"".utf8))
            }
            try? fh.close()
            guard let r else { continue }
            var end = r.upperBound
            while end < data.endIndex, data[end] != UInt8(ascii: "\"") { end += 1 }
            guard let cwd = String(data: data[r.upperBound..<end], encoding: .utf8) else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue { found.append((cwd, newest.1)) }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

extension String {
    var lowercasedFirst: String {
        guard let f = first else { return self }
        // Keep acronyms like "API" readable.
        if count > 1, self[index(after: startIndex)].isUppercase { return self }
        return f.lowercased() + dropFirst()
    }
}
