import Foundation
import TaskTrackerCore

/// `COMPANION_DEMO=<folder>`: runs with made-up sessions (no Ghostty, voice or Claude calls),
/// writes screenshots of the window and the pill into <folder>, and quits. Used for the README.
enum Demo {
    static let folder: URL? = ProcessInfo.processInfo.environment["COMPANION_DEMO"].map { URL(fileURLWithPath: $0) }
    static var on: Bool { folder != nil }

    static func sessions() -> [Session] {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var list: [Session] = []

        var s = Session(id: "demo-1", pid: 1, cwd: "~/Code/shop-web", title: "Checkout flow refactor",
                        status: .needs, since: ago(1), tty: nil)
        s.tabIndex = 1
        s.needsDetail = "Asks to run npm run build"
        list.append(s)

        s = Session(id: "demo-2", pid: 2, cwd: "~/Code/docs", title: "Release notes for 2.4",
                    status: .done, since: ago(6), tty: nil)
        s.tabIndex = 2
        s.outcomeAt = ago(6)
        list.append(s)

        s = Session(id: "demo-3", pid: 3, cwd: "~/Code/api", title: "Datenbank-Migration planen",
                    status: .done, since: ago(18), tty: nil)
        s.tabIndex = 3
        s.outcomeAt = ago(18)
        s.language = .de
        list.append(s)

        s = Session(id: "demo-4", pid: 4, cwd: "~/Code/shop-web", title: "Fix the flaky login test",
                    status: .working, since: ago(12), tty: nil)
        s.tabIndex = 4
        s.activity = "Editing LoginForm.test.tsx"
        list.append(s)

        s = Session(id: "demo-5", pid: 5, cwd: "~/Code/docs", title: "Search for the docs site",
                    status: .working, since: ago(3), tty: nil)
        s.tabIndex = 5
        s.activity = "Reading search-index.ts"
        list.append(s)

        s = Session(id: "demo-6", pid: 6, cwd: "~/Code/infra", title: "Nightly deploy",
                    status: .shell, since: ago(4), tty: nil)
        s.tabIndex = 6
        list.append(s)
        return list
    }
}

extension Demo {
    /// Writes sample tasks and a sample menu with Task Tracker's own code into a temp folder and
    /// points TASKTRACKER_DATA at it, so the demo never touches the real list.
    @MainActor
    static func prepareTaskData() {
        guard on else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("companion-demo-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tasksFile = dir.appendingPathComponent("tasks.json")
        setenv("TASKTRACKER_DATA", tasksFile.path, 1)

        let store = TaskStore(fileURL: tasksFile)
        let doing = store.add("Add a dark mode toggle to the settings page")
        store.setStatus(doing, to: .inProgress)
        store.add("Rate limit the public search API")
        store.add("Fehlermeldungen im Checkout übersetzen")
        store.add("Empty state for the orders list looks broken on mobile")

        let actions = MenuActions(store: MenuStore(fileURL: dir.appendingPathComponent("menu.json")))
        _ = try? actions.add(repo: "acme/shop-web", pr: 412, kind: .check,
                             text: "Pay with a saved card on staging and land on the receipt",
                             why: "Needs a real card in the payment sandbox", location: "staging", minutes: 2, session: "demo-1")
        _ = try? actions.add(repo: "acme/shop-web", pr: 412, kind: .check,
                             text: "The order email arrives within a minute", minutes: 1, session: "demo-1")
        _ = try? actions.add(repo: "acme/shop-web", pr: 412, kind: .idea,
                             text: "Remember the last payment method per customer", session: "demo-1")
        _ = try? actions.add(repo: "acme/docs", pr: 88, kind: .check,
                             text: "Release notes render on the docs site", location: "docs preview", minutes: 1, session: "demo-2")
        try? MenuStore(fileURL: dir.appendingPathComponent("menu.json")).update { file in
            for i in file.prs.indices {
                file.prs[i].title = file.prs[i].number == 412 ? "Checkout flow refactor" : "Release notes for 2.4"
                file.prs[i].state = .open
            }
        }
    }
}
