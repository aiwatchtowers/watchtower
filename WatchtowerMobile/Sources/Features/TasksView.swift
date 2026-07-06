import Observation
import SwiftUI
import WatchtowerKit
import GRDB

@MainActor
@Observable
final class TasksViewModel {
    private(set) var targets: [Target] = []
    private var cancellable: AnyDatabaseCancellable?

    /// Targets grouped by status, in a stable presentation order.
    var groups: [(status: String, targets: [Target])] {
        let order = ["in_progress", "blocked", "todo", "snoozed", "done", "dismissed"]
        return Dictionary(grouping: targets, by: \.status)
            .sorted { lhs, rhs in
                (order.firstIndex(of: lhs.key) ?? order.count) < (order.firstIndex(of: rhs.key) ?? order.count)
            }
            .map { (status: $0.key, targets: $0.value.sorted { $0.priorityOrder < $1.priorityOrder }) }
    }

    func start(store: ReplicaStore) {
        guard cancellable == nil else { return }
        cancellable = ReplicaObserver.observe(Target.self, kind: .target, in: store) { [weak self] items in
            self?.targets = items
        }
    }
}

struct TasksView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = TasksViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    ForEach(model.groups, id: \.status) { group in
                        Section(group.status.replacingOccurrences(of: "_", with: " ").capitalized) {
                            ForEach(group.targets) { target in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(target.text).font(.subheadline)
                                    HStack(spacing: 6) {
                                        Badge(text: target.priority, color: color(target.statusColor))
                                        if let due = target.dueDateFormatted {
                                            Badge(text: due, color: target.isOverdue ? .red : .gray)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .overlay { if model.targets.isEmpty { ContentUnavailableView("No tasks", systemImage: "checklist") } }
                SyncStatusFooter()
            }
            .navigationTitle("Tasks")
        }
        .onAppear { model.start(store: env.store) }
    }
}
