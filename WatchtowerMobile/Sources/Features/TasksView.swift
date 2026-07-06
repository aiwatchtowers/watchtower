import GRDB
import Observation
import os
import SwiftUI
import WatchtowerKit

@MainActor
@Observable
final class TasksViewModel {
    private(set) var targets: [Target] = []
    /// The raw overlay rows (pending + failed), observed alongside the slice.
    private(set) var pending: [PendingAction] = []
    /// Set when an enqueue/retry/dismiss write itself throws (no overlay row
    /// exists to carry the failure); rendered as a plain dismissable banner.
    private(set) var actionErrorMessage: String?

    private var cancellable: AnyDatabaseCancellable?
    private var store: ReplicaStore?
    private var outbox: ActionOutbox?
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "TasksViewModel")

    /// Targets grouped by status, in a stable presentation order.
    var groups: [(status: String, targets: [Target])] {
        let order = ["in_progress", "blocked", "todo", "snoozed", "done", "dismissed"]
        return Dictionary(grouping: targets, by: \.status)
            .sorted { lhs, rhs in
                (order.firstIndex(of: lhs.key) ?? order.count) < (order.firstIndex(of: rhs.key) ?? order.count)
            }
            .map { (status: $0.key, targets: $0.value.sorted { $0.priorityOrder < $1.priorityOrder }) }
    }

    func start(store: ReplicaStore, outbox: ActionOutbox) {
        guard cancellable == nil else { return }
        self.store = store
        self.outbox = outbox
        cancellable = ReplicaObserver.observeWithPendingActions(
            Target.self, kind: .target, in: store
        ) { [weak self] items, pending in
            self?.targets = items
            self?.pending = pending
        }
    }

    // MARK: - Quick actions
    // Typed per-row methods: the ActionKind ↔ target recordName pairing lives
    // HERE and nowhere else — there is deliberately no generic
    // act-on-any-record path (Task 3 review note).

    func markDone(_ target: Target) async {
        await enqueue(.targetDone, target: target)
    }

    func snooze(_ target: Target, option: SnoozeOption, now: Date = Date()) async {
        await enqueue(.targetSnooze, target: target, params: ActionOutbox.snoozeParams(until: option.until(now: now)))
    }

    /// Create sheet → `task_create`: entity-less by design (the desktop mints
    /// the id; the new row arrives back via slice hydration).
    func createTarget(text: String) async {
        guard let outbox else {
            assertionFailure("action before start(store:outbox:)")
            return
        }
        do {
            _ = try await outbox.enqueue(
                kind: .taskCreate,
                entityRecordName: nil,
                params: ["text": .string(text)]
            )
        } catch {
            report(error, doing: PendingOverlay.label(of: .taskCreate))
        }
    }

    private func enqueue(_ kind: ActionKind, target: Target, params: [String: JSONValue] = [:]) async {
        guard let outbox else {
            assertionFailure("action before start(store:outbox:)")
            return
        }
        do {
            _ = try await outbox.enqueue(
                kind: kind,
                entityRecordName: SliceKind.target.recordName(id: String(target.id)),
                params: params
            )
        } catch {
            report(error, doing: PendingOverlay.label(of: kind))
        }
    }

    // MARK: - Overlay

    /// The pending action decorating this row (nil = render normally):
    /// `target_done` → strike-through + chip, `target_snooze` → dim + chip.
    /// Chip suppression applies when the target's status already matches.
    func chip(for target: Target) -> PendingAction? {
        PendingOverlay.chip(
            forRecordName: SliceKind.target.recordName(id: String(target.id)),
            status: target.status,
            in: pending
        )
    }

    var failedActions: [PendingAction] {
        PendingOverlay.failed(in: pending, kinds: [.targetDone, .targetSnooze, .taskCreate])
    }

    func retry(_ failed: PendingAction) async {
        guard let outbox, let store else { return }
        do {
            try await PendingOverlay.retry(failed, outbox: outbox, store: store)
        } catch {
            report(error, doing: "Retry")
        }
    }

    func dismissFailure(_ failed: PendingAction) {
        guard let store else { return }
        do {
            try store.removePendingAction(id: failed.id)
        } catch {
            report(error, doing: "Dismiss")
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    private func report(_ error: Error, doing label: String) {
        Self.logger.error("\(label, privacy: .public) failed to enqueue: \(error.localizedDescription, privacy: .public)")
        actionErrorMessage = "\(label) failed: \(error.localizedDescription)"
    }
}

struct TasksView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = TasksViewModel()
    @State private var snoozeTarget: Target?
    @State private var showCreateSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    if let message = model.actionErrorMessage {
                        ActionErrorRow(message: message) { model.clearActionError() }
                    }
                    ForEach(model.failedActions) { failed in
                        FailedActionBanner(
                            failed: failed,
                            onRetry: { Task { await model.retry(failed) } },
                            onDismiss: { model.dismissFailure(failed) }
                        )
                    }
                    ForEach(model.groups, id: \.status) { group in
                        Section(group.status.replacingOccurrences(of: "_", with: " ").capitalized) {
                            ForEach(group.targets) { target in
                                row(target)
                            }
                        }
                    }
                }
                .overlay { if model.targets.isEmpty { ContentUnavailableView("No tasks", systemImage: "checklist") } }
                SyncStatusFooter()
            }
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreateSheet = true } label: {
                        Label("New Task", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateTargetSheet { text in
                    await model.createTarget(text: text)
                }
            }
            .confirmationDialog(
                "Snooze until",
                isPresented: Binding(
                    get: { snoozeTarget != nil },
                    set: { if !$0 { snoozeTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let target = snoozeTarget {
                    ForEach(SnoozeOption.allCases) { option in
                        Button(option.label) { Task { await model.snooze(target, option: option) } }
                    }
                }
            }
        }
        .onAppear { model.start(store: env.store, outbox: env.outbox) }
    }

    @ViewBuilder
    private func row(_ target: Target) -> some View {
        let chip = model.chip(for: target)
        VStack(alignment: .leading, spacing: 4) {
            Text(target.text)
                .font(.subheadline)
                // Optimistic done: struck through while the echo is pending.
                .strikethrough(chip?.action.kind == .targetDone)
            HStack(spacing: 6) {
                Badge(text: target.priority, color: color(target.statusColor))
                if let due = target.dueDateFormatted {
                    Badge(text: due, color: target.isOverdue ? .red : .gray)
                }
                if chip != nil { Badge(text: "pending", color: .blue) }
            }
        }
        .padding(.vertical, 2)
        .opacity(chip?.action.kind == .targetSnooze ? 0.45 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if target.status != "done" && target.status != "dismissed" {
                Button { Task { await model.markDone(target) } } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .leading) {
            Button { snoozeTarget = target } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
            .tint(.indigo)
        }
    }
}
