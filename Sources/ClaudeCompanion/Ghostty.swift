import AppKit

struct GhosttyTerm {
    let tty: String
    let tabIndex: Int
    let windowId: String
    var tabId: String = ""
    /// The title the terminal itself has (set by Claude Code or a tab-status script), under
    /// any name the companion gave its tab.
    var title: String = ""
}

struct GhosttySnapshot {
    var terms: [String: GhosttyTerm] = [:]
    var frontWindow: String?
    /// The terminal you are looking at in Ghostty's front window.
    var frontTTY: String?
    /// Each window's tab ids, in order.
    var tabs: [String: [String]] = [:]
    /// False when Ghostty didn't answer (the script failed or timed out): then the snapshot
    /// says nothing about which tabs exist.
    var ok = true
}

/// Where a new tab goes.
enum GhosttyTarget: Equatable {
    case front
    case window(String)
    case newWindow
}

/// Drives Ghostty through its AppleScript dictionary (Ghostty 1.3+).
/// Every call runs on one serial background queue; nothing blocks the UI.
final class Ghostty {
    static let bundleId = "com.mitchellh.ghostty"
    private let queue = DispatchQueue(label: "companion.ghostty", qos: .userInitiated)

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId
    }

    static func activate() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// An AppleScript string literal.
    static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs AppleScript through /usr/bin/osascript: in-process NSAppleScript can hang
    /// waiting for Apple Event replies off the main thread. A stuck call is killed after 8 s.
    private func run(_ source: String, timeout: TimeInterval = 8) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        do { try p.run() } catch { return nil }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        if p.terminationStatus != 0 {
            NSLog("[companion] Ghostty AppleScript failed: \(String(data: err, encoding: .utf8) ?? "")")
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }

    private func async(_ source: String, _ done: ((String?) -> Void)? = nil) {
        queue.async { [weak self] in
            let r = self?.run(source)
            if let done { DispatchQueue.main.async { done(r) } }
        }
    }

    // MARK: reading

    func snapshot(_ done: @escaping (GhosttySnapshot) -> Void) {
        guard Self.isRunning else { done(GhosttySnapshot()); return }
        let src = """
        tell application "Ghostty"
          set out to ""
          set fw to ""
          try
            set fw to id of front window
            set out to out & "front|" & fw & "|" & (tty of focused terminal of selected tab of front window) & linefeed
          end try
          repeat with w in windows
            set wid to id of w
            repeat with t in tabs of w
              set idx to index of t
              set tid to id of t
              set out to out & "tab|" & wid & "|" & idx & "|" & tid & linefeed
              repeat with term in terminals of t
                set out to out & "term|" & wid & "|" & idx & "|" & (tty of term) & "|" & tid & "|" & (name of term) & linefeed
              end repeat
            end repeat
          end repeat
          return out
        end tell
        """
        async(src) { out in
            var snap = GhosttySnapshot()
            snap.ok = out != nil
            var tabs: [String: [(Int, String)]] = [:]
            for line in (out ?? "").split(separator: "\n") {
                let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if f.first == "front", f.count >= 3 {
                    snap.frontWindow = f[1]
                    snap.frontTTY = f[2]
                } else if f.first == "tab", f.count >= 4, let idx = Int(f[2]) {
                    tabs[f[1], default: []].append((idx, f[3]))
                } else if f.first == "term", f.count >= 4, let idx = Int(f[2]) {
                    // A tab can hold splits; keep the first (lowest) index per tty.
                    if snap.terms[f[3]] == nil {
                        // The title comes last and can hold "|" itself.
                        snap.terms[f[3]] = GhosttyTerm(tty: f[3], tabIndex: idx, windowId: f[1], tabId: f.count >= 5 ? f[4] : "",
                                                       title: f.count >= 6 ? f[5...].joined(separator: "|") : "")
                    }
                }
            }
            snap.tabs = tabs.mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
            done(snap)
        }
    }

    // MARK: acting

    /// Brings the tab holding this terminal to the front.
    func focus(tty: String) {
        async("""
        tell application "Ghostty"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with term in terminals of t
                if (tty of term) is \(Self.q(tty)) then
                  select tab t
                  activate window w
                  focus term
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "missing"
        end tell
        """)
    }

    /// Types text into the session as if pasted, then optionally presses Enter. `done` says
    /// whether the terminal was found.
    func send(text: String, tty: String, submit: Bool = true, done: ((Bool) -> Void)? = nil) {
        let enter = submit ? "delay 0.2\n      send key \"enter\" to term" : ""
        async("""
        tell application "Ghostty"
          repeat with term in terminals
            if (tty of term) is \(Self.q(tty)) then
              input text \(Self.q(text)) to term
              \(enter)
              return "ok"
            end if
          end repeat
          return "missing"
        end tell
        """) { r in done?(r == "ok") }
    }

    func sendKey(_ key: String, modifiers: String? = nil, tty: String) {
        let mods = modifiers.map { " modifiers \(Self.q($0))" } ?? ""
        async("""
        tell application "Ghostty"
          repeat with term in terminals
            if (tty of term) is \(Self.q(tty)) then
              send key \(Self.q(key))\(mods) to term
              return "ok"
            end if
          end repeat
          return "missing"
        end tell
        """)
    }

    func close(tty: String) {
        async("""
        tell application "Ghostty"
          repeat with term in terminals
            if (tty of term) is \(Self.q(tty)) then
              close term
              return "ok"
            end if
          end repeat
          return "missing"
        end tell
        """)
    }

    /// Opens a new tab in `cwd` (in the front window, a given one, or a new window), types
    /// `input` followed by Enter (nil: nothing), and reports the new terminal's tty (nil if
    /// Ghostty didn't say).
    func newTab(cwd: String, input: String?, target: GhosttyTarget = .front, done: ((String?) -> Void)? = nil) {
        let typed = input.map { "set initial input of cfg to \(Self.q($0)) & linefeed" } ?? ""
        let place: String
        switch target {
        case .front:
            place = """
              if (count of windows) > 0 then
                set t to new tab in front window with configuration cfg
              else
                set w to new window with configuration cfg
                set t to selected tab of w
              end if
            """
        case .window(let id):
            place = """
              set w to missing value
              repeat with x in windows
                if (id of x) is \(Self.q(id)) then set w to x
              end repeat
              if w is missing value then
                set w to new window with configuration cfg
                set t to selected tab of w
              else
                set t to new tab in w with configuration cfg
                activate window w
              end if
            """
        case .newWindow:
            place = """
              set w to new window with configuration cfg
              set t to selected tab of w
            """
        }
        async("""
        tell application "Ghostty"
          set cfg to new surface configuration
          set initial working directory of cfg to \(Self.q(cwd))
          \(typed)
        \(place)
          activate
          repeat 15 times
            try
              set x to tty of focused terminal of t
              if x is not "" then return x
            end try
            delay 0.2
          end repeat
          return ""
        end tell
        """) { out in
            let tty = (out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            done?(tty.isEmpty ? nil : tty)
        }
    }

    /// A tab title to set: the tab, the title ("" gives the tab its own title back), and the
    /// title the companion set before ("" for none).
    struct TabName: Equatable {
        let tab: String
        let name: String
        let was: String
    }

    /// Sets tab titles. A tab is only changed while its title is still the companion's (or
    /// none), so a title you gave it yourself stays. `done` says whether Ghostty answered.
    /// `wait` runs it right here with a short timeout (for quitting).
    func setTabNames(_ names: [TabName], wait: Bool = false, done: ((Bool) -> Void)? = nil) {
        guard !names.isEmpty, Self.isRunning else { done?(true); return }
        let list = names.map { "{\(Self.q($0.tab)), \(Self.q($0.name)), \(Self.q($0.was))}" }.joined(separator: ", ")
        let src = """
        tell application "Ghostty"
          set pairs to {\(list)}
          repeat with w in windows
            repeat with t in tabs of w
              set tid to id of t
              repeat with p in pairs
                if (item 1 of p) is tid then
                  set cur to name override of t
                  if cur is (item 3 of p) or cur is "" then set name override of t to (item 2 of p)
                end if
              end repeat
            end repeat
          end repeat
          return "ok"
        end tell
        """
        if wait {
            done?(run(src, timeout: 2) == "ok")
        } else {
            async(src) { out in done?(out == "ok") }
        }
    }

    /// Puts a window's tabs in this order (tab ids), then selects the tab that was selected.
    /// Ghostty moves the selected tab, so each one is selected before it moves.
    func reorder(window: String, tabs order: [String]) {
        let list = order.map { Self.q($0) }.joined(separator: ", ")
        async("""
        tell application "Ghostty"
          set w to missing value
          repeat with x in windows
            if (id of x) is \(Self.q(window)) then set w to x
          end repeat
          if w is missing value then return "missing"
          set sel to id of selected tab of w
          set order to {\(list)}
          repeat with i from 1 to count of order
            repeat with t in tabs of w
              if (id of t) is (item i of order) then
                set d to i - (index of t)
                if d is not 0 then
                  select tab t
                  perform action ("move_tab:" & d) on focused terminal of t
                  delay 0.05
                end if
                exit repeat
              end if
            end repeat
          end repeat
          repeat with t in tabs of w
            if (id of t) is sel then select tab t
          end repeat
          return "ok"
        end tell
        """)
    }
}
