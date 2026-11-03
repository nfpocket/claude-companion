import Foundation
import TaskTrackerCore
import TaskTrackerUI

/// An open task (In Progress or Todo), as the orbit window shows it.
struct Todo: Identifiable, Equatable {
    enum Stage: String { case inProgress, todo }

    let taskID: UUID
    let title: String
    let stage: Stage
    let folder: String?
    /// Absolute paths of attached images, so Claude can read them.
    let images: [String]

    var id: UUID { taskID }

    /// What gets pasted into a session: the task, then its images' paths.
    var pasteText: String {
        images.isEmpty ? title : title + "\n\n" + images.joined(separator: "\n")
    }
}

extension TaskStore {
    /// In Progress, then Todo, folders flattened, in the list's own order.
    var openTodos: [Todo] {
        var out: [Todo] = []
        for (stage, status) in [(Todo.Stage.inProgress, TaskStatus.inProgress), (.todo, .todo)] {
            for entry in list.entries(in: status) {
                switch entry {
                case .task(let t):
                    out.append(todo(t, stage, nil))
                case .folder(let f):
                    out.append(contentsOf: f.tasks.map { todo($0, stage, f.title) })
                }
            }
        }
        return out
    }

    private func todo(_ t: TaskItem, _ stage: Todo.Stage, _ folder: String?) -> Todo {
        Todo(taskID: t.id, title: t.title.trimmingCharacters(in: .whitespacesAndNewlines),
             stage: stage, folder: folder, images: t.images.map { imageURL($0).path })
    }
}

extension MenuPanel {
    /// The menu's PRs that the given Claude Code session opened, with their items.
    func groups(forSession id: String) -> [(pr: MenuPR, items: [MenuItem])] {
        file.visibleGroups().filter { $0.pr.session == id }
    }

    /// Checks and ideas still waiting on you for that session.
    func openCount(forSession id: String) -> Int {
        groups(forSession: id).reduce(0) { $0 + $1.items.filter { $0.status == .open }.count }
    }
}
