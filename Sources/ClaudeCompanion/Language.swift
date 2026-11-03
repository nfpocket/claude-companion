import Foundation

/// The languages the companion speaks. Sessions are mostly English, some German.
enum Lang: String {
    case en, de

    /// From an ISO code such as Scribe's "deu" / "eng" or "de-DE".
    static func from(code: String?) -> Lang {
        (code ?? "").lowercased().hasPrefix("de") ? .de : .en
    }

    /// German or English, judged by common words in the text.
    static func detect(_ parts: [String?]) -> Lang {
        var de = 0, en = 0
        for part in parts.compactMap({ $0 }) {
            let words = part.prefix(3000).lowercased().split { !$0.isLetter && $0 != "'" }
            for w in words {
                let s = String(w)
                if german.contains(s) { de += 1 } else if english.contains(s) { en += 1 }
                if s.contains(where: { "äöüß".contains($0) }) { de += 1 }
            }
        }
        return de > en ? .de : .en
    }

    var name: String { self == .de ? "German" : "English" }

    /// For the macOS voice fallback.
    var speechLocale: String { self == .de ? "de-DE" : "en-US" }

    // Words that are common in one language and rare in the other ("was", "will",
    // "die", "an", "so" are left out on purpose).
    private static let german: Set<String> = [
        "der", "das", "und", "ist", "nicht", "ich", "du", "wir", "ihr", "mit", "für", "auf", "ein", "eine",
        "einen", "einem", "einer", "zu", "von", "den", "dem", "des", "es", "sie", "auch", "bitte", "kannst",
        "könnte", "wie", "noch", "jetzt", "schon", "aber", "oder", "wenn", "dass", "haben", "habe", "hat",
        "wird", "werden", "sind", "kein", "keine", "sich", "im", "bei", "nach", "über", "mehr", "soll",
        "sollen", "mal", "dann", "hier", "gibt", "alle", "alles", "nur", "sehr", "wieder", "weil", "damit",
        "diese", "dieser", "dieses", "unser", "mein", "dein", "euch", "uns", "mir", "dir", "mich", "dich",
        "ob", "kann", "muss", "sollte", "gerade", "bereits", "neue", "neuen", "wurde", "wurden", "ja", "nein",
        "gut", "danke", "machen", "mach", "zum", "zur", "beim", "vom", "doch", "denn", "etwas", "nichts",
    ]

    private static let english: Set<String> = [
        "the", "and", "is", "not", "to", "of", "a", "it", "you", "that", "for", "with", "on", "this", "are",
        "be", "can", "please", "what", "how", "now", "have", "has", "but", "or", "if", "from", "just", "i",
        "we", "they", "there", "which", "would", "should", "could", "it's", "don't", "been", "were", "into",
        "about", "your", "my", "our", "its", "then", "than", "these", "those", "all", "any", "some", "only",
        "here", "when", "where", "why", "do", "does", "did", "done", "need", "make", "made", "let's", "i'm",
        "yes", "thanks", "after", "before", "still", "already", "also",
    ]
}

/// What the companion says, in English and German.
enum Phrase {
    static func list(_ items: [String], _ l: Lang) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + (l == .de ? " und " : " and ") + items.last!
        }
    }

    static func number(_ n: Int, _ l: Lang) -> String {
        let en = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        let de = ["Keine", "Eine", "Zwei", "Drei", "Vier", "Fünf", "Sechs", "Sieben", "Acht", "Neun", "Zehn"]
        let words = l == .de ? de : en
        return n < words.count ? words[n] : "\(n)"
    }

    static func done(_ names: [String], _ l: Lang) -> String {
        if l == .de { return "\(list(names, l)) \(names.count == 1 ? "ist" : "sind") fertig." }
        return "\(list(names, l)) \(names.count == 1 ? "is" : "are") done."
    }

    static func needsYou(_ names: [String], _ l: Lang) -> String {
        if l == .de { return "\(list(names, l)) \(names.count == 1 ? "braucht" : "brauchen") dich." }
        return "\(list(names, l)) \(names.count == 1 ? "needs" : "need") you."
    }

    static func failed(_ names: [String], _ l: Lang) -> String {
        if l == .de { return "\(list(names, l)) \(names.count == 1 ? "ist" : "sind") mit einem Fehler stehen geblieben." }
        return "\(list(names, l)) stopped on an error."
    }

    static func thingsNeedYou(_ n: Int, _ l: Lang) -> String {
        if l == .de { return n == 1 ? "Eine Sache braucht dich." : "\(number(n, l)) Sachen brauchen dich." }
        return n == 1 ? "One thing needs you." : "\(number(n, l)) things need you."
    }

    static func nothingNeedsYou(_ l: Lang) -> String {
        l == .de ? "Gerade braucht dich nichts." : "Nothing needs you right now."
    }

    static func stillWorking(count n: Int, _ l: Lang) -> String {
        if l == .de { return n == 1 ? "Eine läuft noch." : "\(number(n, l)) laufen noch." }
        return "\(number(n, l)) still working."
    }

    static func stillWorking(_ names: [String], activity: String?, _ l: Lang) -> String {
        if names.count == 1 {
            if l == .de { return "\(names[0]) arbeitet noch." }
            return "\(names[0]) is still working" + (activity.map { ": " + $0.lowercasedFirst } ?? "") + "."
        }
        if l == .de { return "\(number(names.count, l)) arbeiten noch: \(list(names, l))." }
        return "\(number(names.count, l)) are still working: \(list(names, l))."
    }

    static func finishedEarlier(_ names: [String], _ l: Lang) -> String {
        l == .de ? "Vorhin fertig geworden: \(list(names, l))." : "Finished earlier: \(list(names, l))."
    }

    static func noSessions(_ l: Lang) -> String {
        l == .de ? "Gerade ist keine Session offen." : "No sessions are open right now."
    }

    /// Why a session is waiting, from the (English) status line, as a spoken phrase.
    static func waitingReason(_ detail: String?, _ l: Lang) -> String {
        guard let d = detail else { return l == .de ? "wartet auf dich" : "waiting for you" }
        guard l == .de else { return d.lowercasedFirst }
        func after(_ p: String) -> String? { d.hasPrefix(p) ? String(d.dropFirst(p.count)) : nil }
        if let x = after("Asks to run ") { return "möchte \(x) ausführen" }
        if let x = after("Asks to edit ") { return "möchte \(x) bearbeiten" }
        if let x = after("Asks to use ") { return "möchte \(x) benutzen" }
        if let x = after("Asks you: ") { return "fragt dich: \(x)" }
        if d.hasPrefix("Has a question") { return "hat eine Frage an dich" }
        if d.hasPrefix("Has a plan") { return "hat einen Plan zum Freigeben" }
        return "wartet auf dich"
    }
}
