import Foundation

/// An open task from Task Tracker (https://github.com/nfpocket/task-tracker).
struct Todo: Identifiable, Equatable {
    enum Stage: String { case inProgress, todo }

    let id: String
    let title: String
    let stage: Stage
    let folder: String?
    /// Absolute paths of attached images, so Claude can read them.
    let images: [String]

    /// What gets pasted into a session: the task, then its images' paths.
    var pasteText: String {
        images.isEmpty ? title : title + "\n\n" + images.joined(separator: "\n")
    }
}

/// Reads Task Tracker's data file and reports its open tasks (In Progress, then Todo).
/// Read-only: Task Tracker stays the place where tasks are added and changed.
final class TodoStore {
    /// Open tasks, and whether Task Tracker's file exists at all.
    var onUpdate: (([Todo], Bool) -> Void)?

    private let queue = DispatchQueue(label: "companion.todos", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastSeen: Date?

    /// The same place Task Tracker uses, including its TASKTRACKER_DATA override.
    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["TASKTRACKER_DATA"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskTracker/tasks.json")
    }

    func start() {
        if Demo.on {
            let list = Demo.todos()
            DispatchQueue.main.async { [weak self] in self?.onUpdate?(list, true) }
            return
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(300))
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    private func check() {
        let url = Self.fileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else {
            if lastSeen != .distantPast {
                lastSeen = .distantPast
                DispatchQueue.main.async { [weak self] in self?.onUpdate?([], false) }
            }
            return
        }
        guard modified != lastSeen else { return }
        // A file caught mid-write doesn't parse; leave lastSeen alone and try again next tick.
        guard let list = Self.parse(url) else { return }
        lastSeen = modified
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(list, true) }
    }

    static func parse(_ url: URL) -> [Todo]? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sections = root["sections"] as? [[String: Any]] else { return nil }
        let attachments = url.deletingLastPathComponent().appendingPathComponent("attachments")

        func todo(_ t: [String: Any], _ stage: Todo.Stage, _ folder: String?) -> Todo? {
            guard let id = t["id"] as? String, let title = t["title"] as? String else { return nil }
            let images = (t["images"] as? [[String: Any]] ?? []).compactMap { $0["fileName"] as? String }
                .map { attachments.appendingPathComponent($0).path }
            return Todo(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        stage: stage, folder: folder, images: images)
        }

        var out: [Todo] = []
        for stage in [Todo.Stage.inProgress, .todo] {
            guard let section = sections.first(where: { $0["status"] as? String == stage.rawValue }),
                  let entries = section["entries"] as? [[String: Any]] else { continue }
            for entry in entries {
                if let t = entry["task"] as? [String: Any], let item = todo(t, stage, nil) {
                    out.append(item)
                } else if let f = entry["folder"] as? [String: Any] {
                    let name = f["title"] as? String
                    for t in f["tasks"] as? [[String: Any]] ?? [] {
                        if let item = todo(t, stage, name) { out.append(item) }
                    }
                }
            }
        }
        return out
    }
}
