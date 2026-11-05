import Foundation
import TaskTrackerCore

/// `COMPANION_DEMO=<folder>`: runs with made-up sessions (no Ghostty, voice or Claude calls),
/// writes screenshots of the window and the pill into <folder>, and quits. Used for the README.
enum Demo {
    static let folder: URL? = ProcessInfo.processInfo.environment["COMPANION_DEMO"].map { URL(fileURLWithPath: $0) }
    static var on: Bool { folder != nil }
    /// `COMPANION_DEMO_SET=large`: 19 sessions in 12 of 50 projects, in six workspaces.
    static let large = ProcessInfo.processInfo.environment["COMPANION_DEMO_SET"] == "large"
    /// `COMPANION_DEMO_LAYOUT=orbit|graph|sidebar` pins a layout for the screenshots.
    static let layout: LayoutChoice? = ProcessInfo.processInfo.environment["COMPANION_DEMO_LAYOUT"].flatMap(LayoutChoice.init(rawValue:))

    private static func ws(_ name: String) -> String { ("~/Projects/\(name)" as NSString).expandingTildeInPath }
    static var pinned: [String] { large ? ["~/Projects/acme/acme-api", ws("lab")] : [] }
    static var navOpen: Set<String> { large ? [ws("acme")] : [] }

    /// The projects without sessions the large demo lists.
    static func knownRepos() -> [String] {
        guard large else { return [] }
        let idle: [String: [String]] = [
            "acme": ["admin", "auth", "billing", "cli", "design", "docs", "infra", "mail", "search"],
            "globex": ["analytics", "app", "newsletter", "intranet", "tracking"],
            "lab": ["ez-rec", "magazine", "oyster", "testing-sdk", "trackpad-scale", "flow", "blast-test"],
            "personal": ["notes", "scripts"],
            "initech": ["portal", "app", "api", "reports", "billing", "crm", "docs", "etl", "infra", "mobile", "sso"],
            "oss": ["swift-format", "homebrew-tap", "ghostty-themes", "zed-extensions"],
        ]
        return idle.sorted { $0.key < $1.key }.flatMap { ws, names in
            names.map { n in "~/Projects/\(ws)/" + (["lab", "personal", "oss"].contains(ws) ? n : "\(ws)-\(n)") }
        }
    }

    static func sessions() -> [Session] {
        if large { return largeSessions() }
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
    /// 19 sessions in 12 projects across four workspaces, for the sidebar and graph screenshots.
    static func largeSessions() -> [Session] {
        let now = Date()
        var list: [Session] = []
        func add(_ path: String, _ title: String, _ status: SessionStatus, _ minutes: Double,
                 needs: String? = nil, activity: String? = nil) {
            let n = list.count + 1
            var s = Session(id: "demo-\(n)", pid: Int32(n), cwd: "~/Projects/" + path, title: title,
                            status: status, since: now.addingTimeInterval(-minutes * 60), tty: nil)
            s.tabIndex = n
            s.needsDetail = needs
            s.activity = activity
            if status == .done || status == .failed { s.outcomeAt = s.since }
            list.append(s)
        }
        add("acme/acme-api", "Release PR for Thursday", .needs, 2, needs: "Asks to run gh pr create --base main")
        add("acme/acme-api", "N+1 query in /projects", .working, 7, activity: "Editing projects_controller.rb")
        add("acme/acme-api", "Sprint board fields via GraphQL", .done, 11)
        add("acme/acme-app", "Push notifications on iOS", .needs, 4, needs: "Asks to edit AppDelegate.swift")
        add("acme/acme-app", "Offline cache for projects", .working, 15, activity: "Reading ProjectStore.ts")
        add("acme/acme-fleet", "Session cards v2", .working, 3, activity: "Editing SessionCard.vue")
        add("acme/acme-fleet", "Fleet UI cleanup", .idle, 40)
        add("acme/acme-frontend", "Filter in the project dashboard", .done, 25)
        add("acme/acme-frontend", "Dark mode tokens", .working, 9, activity: "Editing tokens.css")
        add("acme/acme-logbook", "Release entry", .idle, 55)
        add("globex/globex-portal", "Login with Azure AD", .needs, 6, needs: "Has a question for you")
        add("globex/globex-cms", "Import old articles", .failed, 8)
        add("globex/globex-web", "Replace the hero slider", .working, 12, activity: "Editing Hero.tsx")
        add("globex/globex-web", "Lighthouse under 90", .shell, 5)
        add("globex/globex-shop", "Shipping costs for Switzerland", .done, 14)
        add("lab/claude-hub", "Workspaces in the sidebar", .working, 20, activity: "Editing Sidebar.swift")
        add("lab/claude-hub", "Notch pill polish", .idle, 70)
        add("lab/task-tracker", "Reminders via iCloud", .done, 31)
        add("personal/dotfiles", "Zsh prompt cleanup", .idle, 90)
        return list
    }

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

extension Demo {
    /// A made-up conversation for the Chat tab.
    static func chat(_ sessionId: String) -> [ChatItem] {
        let now = Date()
        var items: [ChatItem] = []
        func you(_ t: String, _ minutes: Double) {
            items.append(ChatItem(id: "\(sessionId)-\(items.count)", kind: .you, text: t, at: now.addingTimeInterval(-minutes * 60)))
        }
        func claude(_ t: String) {
            var i = ChatItem(id: "\(sessionId)-\(items.count)", kind: .claude, text: t, at: now)
            i.blocks = MD.blocks(t)
            items.append(i)
        }
        func steps(_ list: [(String, [String: Any])]) {
            let s = list.enumerated().map { n, step in
                ChatStep(id: "\(sessionId)-\(items.count)-\(n)", tool: step.0, text: Activity.describe(step.0, step.1),
                         detail: ChatTranscript.detail(step.0, step.1))
            }
            items.append(ChatItem(id: "\(sessionId)-\(items.count)", kind: .steps, text: "", at: now, steps: s))
        }
        switch sessionId {
        case "demo-1":
            you("Split the payment step out of the checkout into its own component. Saved cards have to keep working.", 9)
            claude("I'll look at how the checkout steps are wired first.")
            steps([("Read", ["file_path": "/Users/demo/Code/shop-web/src/checkout/Checkout.tsx"]),
                   ("Grep", ["pattern": "usePaymentMethod"]),
                   ("Read", ["file_path": "/Users/demo/Code/shop-web/src/checkout/usePaymentMethod.ts"])])
            claude("The payment step lives inside `Checkout.tsx` today, together with the saved-card picker. I'll move both into `PaymentStep.tsx` and keep `usePaymentMethod` as it is, so saved cards take the same path as before.")
            steps([("Write", ["file_path": "/Users/demo/Code/shop-web/src/checkout/PaymentStep.tsx"]),
                   ("Edit", ["file_path": "/Users/demo/Code/shop-web/src/checkout/Checkout.tsx"]),
                   ("Bash", ["command": "npm run build", "description": "Build the app to catch type errors"])])
        case "demo-2":
            you("Write the release notes for 2.4 from the PRs merged since 2.3.", 14)
            steps([("Bash", ["command": "gh pr list --state merged --search \"merged:>2026-10-01\" --limit 50", "description": "List the PRs merged since 2.3"]),
                   ("Read", ["file_path": "/Users/demo/Code/docs/CHANGELOG.md"]),
                   ("Edit", ["file_path": "/Users/demo/Code/docs/CHANGELOG.md"])])
            claude("""
            The notes for **2.4** are in `CHANGELOG.md`:

            ## 2.4
            - Saved cards at checkout
            - Search on the docs site is about twice as fast
            - Fixed: the order email could arrive twice

            I left out the internal refactors. Should I open a PR?
            """)
            you("Yes, open one", 8)
            steps([("Bash", ["command": "git switch -c release-notes-2.4", "description": "Create a branch for the notes"]),
                   ("Bash", ["command": "git commit -am \"Release notes for 2.4\"", "description": "Commit the notes"]),
                   ("Bash", ["command": "gh pr create --fill", "description": "Open the pull request"])])
            claude("Opened **acme/docs#88**. One check is on the menu: whether the notes render on the docs site.")
        default:
            you("Let's get started.", 5)
            claude("On it.")
        }
        return items
    }
}
