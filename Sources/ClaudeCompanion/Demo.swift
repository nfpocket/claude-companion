import Foundation

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
    static func todos() -> [Todo] {
        [
            Todo(id: "t1", title: "Add a dark mode toggle to the settings page", stage: .inProgress, folder: nil, images: []),
            Todo(id: "t2", title: "Rate limit the public search API", stage: .todo, folder: "API", images: []),
            Todo(id: "t3", title: "Fehlermeldungen im Checkout übersetzen", stage: .todo, folder: "API", images: []),
            Todo(id: "t4", title: "Empty state for the orders list looks broken on mobile", stage: .todo, folder: nil, images: ["shot.png"]),
        ]
    }
}
