import Foundation

/// The app's own interface text in English or German (switch: EN | DE in the header).
/// English is the source text; `L("…")` looks up the German version.
/// What the companion *says* follows its own language setting (see `Phrase`).
enum UIText {
    /// Set by AppModel when the app language changes; the views rebuild right after.
    static var lang: Lang = .en

    static func t(_ en: String) -> String {
        guard lang == .de else { return en }
        return de[en] ?? en
    }

    // MARK: text with numbers or names in it

    static func status(_ s: SessionStatus) -> String {
        guard lang == .de else { return s.label }
        switch s {
        case .needs: return "Braucht dich"
        case .failed: return "Fehlgeschlagen"
        case .done: return "Fertig"
        case .working: return "Arbeitet"
        case .shell: return "Hintergrund-Shell"
        case .idle: return "Inaktiv"
        }
    }

    /// Header chips and the pill strip: "2 done", "1 braucht dich".
    static func count(_ s: SessionStatus, _ n: Int) -> String {
        if lang == .de {
            switch s {
            case .needs: return "\(n) \(n == 1 ? "braucht" : "brauchen") dich"
            case .failed: return "\(n) fehlgeschlagen"
            case .done: return "\(n) fertig"
            case .working: return "\(n) \(n == 1 ? "arbeitet" : "arbeiten")"
            case .shell: return "\(n) im Hintergrund"
            case .idle: return "\(n) inaktiv"
            }
        }
        switch s {
        case .needs: return "\(n) needs you"
        case .failed: return "\(n) failed"
        case .done: return "\(n) done"
        case .working: return "\(n) working"
        case .shell: return "\(n) in background"
        case .idle: return "\(n) idle"
        }
    }

    static func watching(_ n: Int) -> String {
        lang == .de ? "Beobachte \(n) Session\(n == 1 ? "" : "s")" : "Watching \(n) session\(n == 1 ? "" : "s")"
    }

    static func thingsNeedYou(_ n: Int) -> String {
        if lang == .de { return n == 1 ? "Eine Sache braucht dich" : "\(Phrase.number(n, .de)) Sachen brauchen dich" }
        return n == 1 ? "One thing needs you" : "\(Phrase.number(n, .en)) things need you"
    }

    static func finished(_ d: Date) -> String {
        (lang == .de ? "Fertig " : "Finished ") + Fmt.ago(d)
    }

    static func countdown(_ verb: String, _ seconds: Int) -> String {
        lang == .de
            ? "\(verb) in \(seconds) s. Drück Esc oder sag „abbrechen“, um es zu stoppen."
            : "\(verb) in \(seconds) s. Press Esc or say “cancel” to stop it."
    }

    /// Why a session waits, for its card (the store writes it in English).
    static func needs(_ detail: String?) -> String {
        guard lang == .de else { return detail ?? "Waiting for you" }
        let r = Phrase.waitingReason(detail, .de)
        return r.prefix(1).uppercased() + r.dropFirst()
    }

    /// What a working session is doing, for its card. Free text written by Claude stays as it is.
    static func activity(_ a: String) -> String {
        guard lang == .de else { return a }
        let map: [(String, String, String)] = [
            ("Editing ", "Bearbeitet ", ""), ("Writing ", "Schreibt ", ""), ("Reading ", "Liest ", ""),
            ("Running a subagent", "Startet einen Subagent", ""), ("Running ", "Führt aus: ", ""),
            ("Subagent: ", "Subagent: ", ""), ("Using the ", "Nutzt den Skill ", " skill"), ("Using ", "Nutzt ", ""),
        ]
        for (en, de, suffix) in map where a.hasPrefix(en) {
            var rest = String(a.dropFirst(en.count))
            if !suffix.isEmpty, rest.hasSuffix(suffix) { rest = String(rest.dropLast(suffix.count)) }
            return de + rest
        }
        let whole: [String: String] = [
            "Searching the code": "Durchsucht den Code",
            "Looking things up online": "Recherchiert online",
            "Updating its task list": "Aktualisiert die Aufgabenliste",
            "Asking you a question": "Stellt dir eine Frage",
            "Proposing a plan": "Schlägt einen Plan vor",
            "Waiting on something": "Wartet auf etwas",
        ]
        return whole[a] ?? a
    }

    // MARK: fixed text

    private static let de: [String: String] = [
        "⌥ Space": "⌥ Leertaste",
        "⌥ Space works from any app, too": "⌥ Leertaste geht auch aus jeder anderen App",
        "and talk": "gedrückt und sprich",
        "anywhere, say it, let go.": "überall gedrückt, sprich und lass los.",
        "App language": "App-Sprache",
        "Ask “what needs me?” or “summarize everything”": "Frag „Was braucht mich?“ oder „Fass alles zusammen“",
        "Be quiet for an hour": "Eine Stunde still sein",
        "Cancel": "Abbrechen",
        "Choose another folder…": "Anderen Ordner wählen …",
        "Claude Companion: click for your sessions": "Claude Companion: klicken für deine Sessions",
        "claude, with your usual settings": "claude, mit deinen üblichen Einstellungen",
        "Close": "Schließen",
        "Close (Esc)": "Schließen (Esc)",
        "Close session": "Session schließen",
        "Closing": "Schließen",
        "Doing it": "Ausführen",
        "Done, not seen": "Fertig, noch nicht angesehen",
        "English voice": "Englische Stimme",
        "Failed": "Fehlgeschlagen",
        "First prompt": "Erster Prompt",
        "Folder": "Ordner",
        "From what you just said · check it, or let it start": "Aus dem, was du gerade gesagt hast · prüf es oder lass es starten",
        "German voice (for German sessions and replies)": "Deutsche Stimme (für deutsche Sessions und Antworten)",
        "Heard": "Gehört",
        "Hold": "Halte",
        "Hold ⌥ Space to talk": "⌥ Leertaste halten und sprechen",
        "Hold Space here (⌥ Space is taken by another app)": "Hier die Leertaste halten (⌥ Leertaste ist von einer anderen App belegt)",
        "Hold to reply": "Halten zum Antworten",
        "Hold to talk": "Halten zum Sprechen",
        "Idle": "Inaktiv",
        "in this window or": "in diesem Fenster oder",
        "Let go to send": "Loslassen zum Senden",
        "Let go to send · Esc cancels": "Loslassen zum Senden · Esc bricht ab",
        "Listening": "Ich höre zu",
        "Listening…": "Ich höre zu …",
        "Listening · let go to send": "Ich höre zu · loslassen zum Senden",
        "Mac voice (free)": "Mac-Stimme (kostenlos)",
        "Microphone access is off (System Settings › Privacy › Microphone)": "Mikrofonzugriff ist aus (Systemeinstellungen › Datenschutz › Mikrofon)",
        "Needs you": "Braucht dich",
        "New Ghostty tab": "Neuer Ghostty-Tab",
        "New session": "Neue Session",
        "No Claude Code sessions are running.\nHold Space and say “start a session in …”, or click Start a session.":
            "Es laufen keine Claude-Code-Sessions.\nHalte die Leertaste und sag „Starte eine Session in …“ oder klick auf Session starten.",
        "No sessions open": "Keine Sessions offen",
        "Not seen yet": "Noch nicht angesehen",
        "Nothing needs you": "Nichts braucht dich",
        "Now": "Jetzt",
        "Only tell me when something needs me": "Nur Bescheid sagen, wenn mich etwas braucht",
        "Open at login": "Bei der Anmeldung öffnen",
        "Open in Ghostty": "In Ghostty öffnen",
        "Open window": "Fenster öffnen",
        "Opens a new Ghostty tab running claude": "Öffnet einen neuen Ghostty-Tab mit claude",
        "Opens in": "Öffnet in",
        "Optional: what should it start on?": "Optional: Womit soll sie anfangen?",
        "Presses Esc in its tab, which interrupts what it is doing.": "Drückt Esc in ihrem Tab und unterbricht, was sie gerade tut.",
        "Quiet": "Still",
        "Read aloud": "Vorlesen",
        "Run scripts/install-hooks.sh so “needs you” shows up.": "Führe scripts/install-hooks.sh aus, damit „braucht dich“ angezeigt wird.",
        "Runs": "Startet",
        "Send now": "Jetzt senden",
        "Sending": "Senden",
        "Sessions are matched loosely: “the fleet one”, “the dashboard session” and “number three” all work. When it isn’t clear which one you mean, I ask instead of guessing.":
            "Sessions werden großzügig erkannt: „die Fleet-Session“, „die Dashboard-Session“ und „Nummer drei“ funktionieren alle. Wenn nicht klar ist, welche du meinst, frage ich nach, statt zu raten.",
        "Skip": "Überspringen",
        "Space": "Leertaste",
        "Speak when a session finishes": "Ansagen, wenn eine Session fertig ist",
        "Speaking": "Ich spreche",
        "Spoken language": "Gesprochene Sprache",
        "Start a session": "Session starten",
        "Start now": "Jetzt starten",
        "Starting": "Start",
        "Status hooks not installed": "Status-Hooks nicht installiert",
        "Stop": "Stopp",
        "Stop now": "Jetzt stoppen",
        "Stop talking": "Aufhören",
        "Stop this turn (sends Esc)": "Diesen Durchlauf stoppen (sendet Esc)",
        "Stopped on an error": "Mit einem Fehler gestoppt",
        "Stopping": "Stoppen",
        "Summarize all": "Alles zusammenfassen",
        "Talk again": "Wieder sprechen",
        "Talk or press Esc to interrupt": "Sprich oder drück Esc zum Unterbrechen",
        "the session": "die Session",
        "Thinking": "Ich denke nach",
        "Thinking…": "Ich denke nach …",
        "Transcribing…": "Wird transkribiert …",
        "Turning your voice into text": "Deine Stimme wird zu Text",
        "Types /exit in its tab and then closes the tab.": "Tippt /exit in ihren Tab und schließt ihn dann.",
        "Waiting for you to confirm.": "Wartet auf deine Bestätigung.",
        "Waiting on a background shell": "Wartet auf eine Hintergrund-Shell",
        "Waiting on a shell": "Wartet auf eine Shell",
        "What needs me?": "Was braucht mich?",
        "What you can say": "Was du sagen kannst",
        "Where it stands": "Wo sie steht",
        "Working": "Arbeitet",
        "Working it out": "Ich überlege",
        "Working out what you mean": "Ich finde heraus, was du meinst",
        "Your last prompt": "Dein letzter Prompt",
        "Overview": "Überblick",
        "Menu": "Menü",
        "Reply": "Antworten",
        "Click to open it in Ghostty": "Klicken, um sie in Ghostty zu öffnen",
        "Tasks": "Aufgaben",
        "Show or hide your tasks and the menu": "Aufgaben und Menü zeigen oder ausblenden",
        "On the menu": "Im Menü",
        "Fix in its session": "In ihrer Session beheben",
        "What went wrong?": "Was ging schief?",
        "Send to the PR": "An den PR senden",
        "Works": "Geht",
        "Problem…": "Problem …",
        "Make issue": "Issue anlegen",
        "Later": "Später",
        "Dismiss": "Verwerfen",
        "Open": "Öffnen",
        "Start a new session with it": "Neue Session damit starten",
        "Choose a folder…": "Ordner wählen …",
        "Paste into a session": "In Session einfügen",
    ]

    /// English keys used in the code that have no German entry (for the build check).
    static func missing(_ keys: [String]) -> [String] { keys.filter { de[$0] == nil } }
}

/// Interface text in the app language.
func L(_ en: String) -> String { UIText.t(en) }

/// Interface text with names or numbers in it, given in both languages.
func ui(_ en: String, _ de: String) -> String { UIText.lang == .de ? de : en }
