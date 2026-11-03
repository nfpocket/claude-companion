import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let claude = home.appendingPathComponent(".claude")
    /// One JSON file per running Claude Code process, written by Claude Code itself.
    static let sessions = claude.appendingPathComponent("sessions")
    /// Transcripts: projects/<cwd slug>/<session id>.jsonl
    static let projects = claude.appendingPathComponent("projects")
    /// Written by ~/.claude/hooks/tab-outcome.sh (done / failed).
    static let outcomes = claude.appendingPathComponent("tab-status")
    /// Written by ~/.claude/hooks/companion-hook.sh.
    static let events = claude.appendingPathComponent("companion/events")

    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeCompanion")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let ttsCache: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeCompanion/tts")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}
