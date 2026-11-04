import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

enum Theme {
    static let bg = Color(hex: 0x141518)
    static let bar = Color(hex: 0x16171B)
    static let panel = Color(hex: 0x18191D)
    static let card = Color(hex: 0x1B1D21)
    static let surface = Color(hex: 0x1E2024)
    static let field = Color(hex: 0x1F2125)
    static let surfaceHi = Color(hex: 0x24272C)
    static let raised = Color(hex: 0x26292E)
    static let border = Color(hex: 0x2E3137)
    static let borderHi = Color(hex: 0x34373D)
    static let hairline = Color(hex: 0x24262B)
    static let ring = Color(hex: 0x2C2F35)
    static let line = Color(hex: 0x2A2D33)
    static let text = Color(hex: 0xECEDEF)
    static let body = Color(hex: 0xD6D8DC)
    static let muted = Color(hex: 0xA1A4AB)
    static let faint = Color(hex: 0x8B8E96)
    static let accent = Color(hex: 0xD97757)
    static let accentLight = Color(hex: 0xF0A385)
    static let ink = Color(hex: 0x1A1210)
    static let eye = Color(hex: 0x20140F)
    static let listen = Color(hex: 0x6AA8FF)
    static let danger = Color(hex: 0xFF8A80)

    static func mono(_ size: CGFloat = 11) -> Font { .system(size: size, design: .monospaced) }
}

enum SessionStatus: String {
    case needs, failed, done, working, shell, idle

    var label: String {
        switch self {
        case .needs: return "Needs you"
        case .failed: return "Failed"
        case .done: return "Done"
        case .working: return "Working"
        case .shell: return "Background shell"
        case .idle: return "Idle"
        }
    }

    var color: Color {
        switch self {
        case .needs: return Color(hex: 0xF2A93B)
        case .failed: return Color(hex: 0xFF7A70)
        case .done: return Color(hex: 0x5BD08A)
        case .working: return Color(hex: 0x6AA8FF)
        case .shell: return Color(hex: 0xB49CFF)
        case .idle: return Color(hex: 0x8B8E96)
        }
    }

    var symbol: String {
        switch self {
        case .needs: return "exclamationmark"
        case .failed: return "xmark"
        case .done: return "checkmark"
        case .working: return "circle.dotted"
        case .shell: return "hourglass"
        case .idle: return "minus"
        }
    }
}

struct Session: Identifiable, Equatable {
    let id: String
    var pid: Int32
    var cwd: String
    var title: String
    var status: SessionStatus
    /// When the current status began (turn start, prompt shown, turn end).
    var since: Date
    var tty: String?
    var tabIndex: Int? = nil
    var activity: String? = nil
    var needsDetail: String? = nil
    var lastPrompt: String? = nil
    var lastPromptAt: Date? = nil
    var lastAnswer: String? = nil
    var outcomeAt: Date? = nil
    var unseen = false
    /// The language the session is held in; summaries and announcements use it.
    var language: Lang = .en
    /// The repo it works in (see `Projects.root`), for grouping sessions by project.
    var project: String = ""

    var folder: String { (cwd as NSString).lastPathComponent }

    var shortcut: String? {
        guard let i = tabIndex, i >= 1, i <= 9 else { return nil }
        return "⌘\(i)"
    }

    /// The status line on a card, in the app's language.
    var statusLine: String {
        switch status {
        case .needs: return UIText.needs(needsDetail)
        case .failed: return L("Stopped on an error")
        case .done: return UIText.finished(outcomeAt ?? since)
        case .working: return activity.map(UIText.activity) ?? L("Working")
        case .shell: return L("Waiting on a background shell")
        case .idle: return L("Idle")
        }
    }

    var metaLine: String {
        switch status {
        case .working, .shell: return "\(folder) · \(Fmt.duration(since))"
        case .needs: return "\(folder) · " + ui("waiting", "wartet") + " \(Fmt.duration(since))"
        default: return folder
        }
    }

    var spokenName: String { Fmt.spokenName(title) }

    /// Orbit order: what needs you first, quiet things last.
    var rank: Int {
        switch status {
        case .needs: return 0
        case .failed: return unseen ? 1 : 5
        case .done: return unseen ? 2 : 6
        case .working: return 3
        case .shell: return 4
        case .idle: return 7
        }
    }
}

enum Fmt {
    static func ago(_ d: Date) -> String {
        let s = -d.timeIntervalSinceNow
        let de = UIText.lang == .de
        if s < 45 { return de ? "gerade eben" : "just now" }
        if s < 3600 { let m = max(1, Int(s / 60)); return de ? "vor \(m) Min." : "\(m) min ago" }
        if s < 86400 { let h = Int(s / 3600); return de ? "vor \(h) Std." : "\(h) h ago" }
        let days = Int(s / 86400)
        return de ? "vor \(days) \(days == 1 ? "Tag" : "Tagen")" : "\(days) d ago"
    }

    static func duration(_ d: Date) -> String {
        let s = -d.timeIntervalSinceNow
        let de = UIText.lang == .de
        if s < 60 { return de ? "<1 Min." : "<1 min" }
        if s < 3600 { return "\(Int(s / 60)) " + (de ? "Min." : "min") }
        if s < 86400 { return "\(Int(s / 3600)) " + (de ? "Std." : "h") }
        return "\(Int(s / 86400)) " + (de ? "T." : "d")
    }

    /// A title short enough to say out loud.
    static func spokenName(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = t.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first) {
            t.removeFirst()
        }
        t = t.replacingOccurrences(of: "…", with: "")
        let words = t.split(separator: " ")
        if words.count > 7 { t = words.prefix(7).joined(separator: " ") }
        return t.isEmpty ? "A session" : t
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    static func number(_ n: Int) -> String {
        let words = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return n < words.count ? words[n] : "\(n)"
    }
}
