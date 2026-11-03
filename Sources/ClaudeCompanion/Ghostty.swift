import AppKit

struct GhosttyTerm {
    let tty: String
    let tabIndex: Int
    let windowId: String
}

struct GhosttySnapshot {
    var terms: [String: GhosttyTerm] = [:]
    var frontWindow: String?
    /// The terminal you are looking at in Ghostty's front window.
    var frontTTY: String?
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
    private func run(_ source: String) -> String? {
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
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
              repeat with term in terminals of t
                set out to out & "term|" & wid & "|" & idx & "|" & (tty of term) & linefeed
              end repeat
            end repeat
          end repeat
          return out
        end tell
        """
        async(src) { out in
            var snap = GhosttySnapshot()
            for line in (out ?? "").split(separator: "\n") {
                let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if f.first == "front", f.count >= 3 {
                    snap.frontWindow = f[1]
                    snap.frontTTY = f[2]
                } else if f.first == "term", f.count >= 4, let idx = Int(f[2]) {
                    // A tab can hold splits; keep the first (lowest) index per tty.
                    if snap.terms[f[3]] == nil {
                        snap.terms[f[3]] = GhosttyTerm(tty: f[3], tabIndex: idx, windowId: f[1])
                    }
                }
            }
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

    /// Opens a new tab (or window) in `cwd`, types `input` followed by Enter, and reports the
    /// new terminal's tty (nil if Ghostty didn't say).
    func newTab(cwd: String, input: String, done: ((String?) -> Void)? = nil) {
        async("""
        tell application "Ghostty"
          set cfg to new surface configuration
          set initial working directory of cfg to \(Self.q(cwd))
          set initial input of cfg to \(Self.q(input)) & linefeed
          if (count of windows) > 0 then
            set t to new tab in front window with configuration cfg
          else
            set w to new window with configuration cfg
            set t to selected tab of w
          end if
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
}
