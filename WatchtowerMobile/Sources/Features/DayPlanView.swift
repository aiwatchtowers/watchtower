import GRDB
import Observation
import os
import SwiftUI
import WatchtowerKit

/// Today's plan on the phone — the mobile counterpart of the desktop's Day
/// Plan screen (`DayPlanView` there), scoped to what a phone is good for:
/// seeing what the day is supposed to look like and crossing items off.
///
/// Only today's plan is published (see `SlicePublisher.sliceSQL`), so there is
/// at most one plan row; a phone that has not synced today's plan yet simply
/// renders nothing.
@MainActor
@Observable
final class DayPlanViewModel {
    private(set) var plan: DayPlan?
    private(set) var items: [DayPlanItem] = []
    private(set) var pending: [PendingAction] = []
    /// Set when an enqueue/retry/dismiss write itself throws (no overlay row
    /// exists to carry the failure) — the InboxViewModel banner discipline.
    private(set) var actionErrorMessage: String?

    private var planCancellable: AnyDatabaseCancellable?
    private var itemsCancellable: AnyDatabaseCancellable?
    private var store: ReplicaStore?
    private var outbox: ActionOutbox?
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "DayPlanViewModel")

    func start(store: ReplicaStore, outbox: ActionOutbox) {
        guard planCancellable == nil else { return }
        self.store = store
        self.outbox = outbox
        planCancellable = ReplicaObserver.observe(DayPlan.self, kind: .dayPlan, in: store) { [weak self] plans in
            self?.plan = plans.first
        }
        itemsCancellable = ReplicaObserver.observeWithPendingActions(
            DayPlanItem.self, kind: .dayPlanItem, in: store
        ) { [weak self] items, pending in
            // The desktop's own order: blocks before backlog, then the
            // planner's order_index (DayPlanQueries.fetchItems).
            self?.items = items.sorted {
                $0.kind == $1.kind
                    ? ($0.orderIndex, $0.id) < ($1.orderIndex, $1.id)
                    : $0.kind == .timeblock
            }
            self?.pending = pending
        }
    }

    var timeblocks: [DayPlanItem] { items.filter { $0.kind == .timeblock } }
    var backlog: [DayPlanItem] { items.filter { $0.kind == .backlog } }

    /// "2 of 5" — done against the whole plan, the desktop's `progress` shape.
    var progress: (done: Int, total: Int) {
        (items.filter { $0.status == .done }.count, items.count)
    }

    // MARK: - Quick actions

    func markDone(_ item: DayPlanItem) async {
        await enqueue(.dayPlanItemDone, item: item)
    }

    func skip(_ item: DayPlanItem) async {
        await enqueue(.dayPlanItemSkip, item: item)
    }

    private func enqueue(_ kind: ActionKind, item: DayPlanItem) async {
        guard let outbox else {
            assertionFailure("action before start(store:outbox:)")
            return
        }
        do {
            _ = try await outbox.enqueue(
                kind: kind,
                entityRecordName: SliceKind.dayPlanItem.recordName(id: String(item.id))
            )
        } catch {
            report(error, doing: PendingOverlay.label(of: kind))
        }
    }

    // MARK: - Overlay

    func chip(for item: DayPlanItem) -> PendingAction? {
        PendingOverlay.chip(
            forRecordName: SliceKind.dayPlanItem.recordName(id: String(item.id)),
            status: item.statusRaw,
            in: pending
        )
    }

    var failedActions: [PendingAction] {
        PendingOverlay.failed(in: pending, kinds: [.dayPlanItemDone, .dayPlanItemSkip])
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

// MARK: - Today's section

/// The plan as it appears on Today: every time block, the first few backlog
/// entries, and a link to the rest. Renders nothing at all when no plan has
/// synced — an empty "Plan" header would read as "the planner produced
/// nothing today", which is a different statement.
struct DayPlanSection: View {
    let model: DayPlanViewModel

    /// Backlog entries shown inline before the "See all" link takes over.
    private static let inlineBacklogLimit = 3

    var body: some View {
        if model.plan != nil {
            Section {
                if let summary = conflictSummary {
                    Label(summary, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(model.timeblocks) { item in
                    DayPlanItemRow(item: item, chip: model.chip(for: item))
                        .dayPlanSwipeActions(item: item, model: model)
                }
                ForEach(model.backlog.prefix(Self.inlineBacklogLimit)) { item in
                    DayPlanItemRow(item: item, chip: model.chip(for: item))
                        .dayPlanSwipeActions(item: item, model: model)
                }
                if model.backlog.count > Self.inlineBacklogLimit {
                    NavigationLink {
                        DayPlanFullView(model: model)
                    } label: {
                        Text("See all \(model.items.count) plan items")
                            .font(.subheadline)
                    }
                }
            } header: {
                Text(header)
            }
        }
    }

    private var header: String {
        let progress = model.progress
        return progress.total == 0
            ? "Plan"
            : "Plan · \(progress.done) of \(progress.total) done"
    }

    private var conflictSummary: String? {
        guard let plan = model.plan, plan.hasConflicts else { return nil }
        return plan.conflictSummary.isEmpty ? "This plan has overlapping blocks" : plan.conflictSummary
    }
}

// MARK: - Full plan

struct DayPlanFullView: View {
    let model: DayPlanViewModel

    var body: some View {
        List {
            if !model.timeblocks.isEmpty {
                Section("Time blocks") {
                    ForEach(model.timeblocks) { item in
                        DayPlanItemRow(item: item, chip: model.chip(for: item))
                            .dayPlanSwipeActions(item: item, model: model)
                    }
                }
            }
            if !model.backlog.isEmpty {
                Section("Backlog") {
                    ForEach(model.backlog) { item in
                        DayPlanItemRow(item: item, chip: model.chip(for: item))
                            .dayPlanSwipeActions(item: item, model: model)
                    }
                }
            }
        }
        .navigationTitle("Today's plan")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Row

struct DayPlanItemRow: View {
    let item: DayPlanItem
    let chip: PendingAction?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .font(.subheadline)
                .foregroundStyle(item.status == .done ? Color.green : Color.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .strikethrough(item.status != .pending, color: .secondary)
                    .foregroundStyle(item.status == .pending ? .primary : .secondary)
                    .lineLimit(2)
                if let range = item.timeRange {
                    Text(range)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !item.rationale.isEmpty {
                    Text(item.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if chip != nil {
                    Badge(text: "pending", color: .blue)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: String {
        switch item.status {
        case .done: return "checkmark.circle.fill"
        case .skipped: return "slash.circle"
        case .pending: return "circle"
        }
    }
}

private extension View {
    /// Done/skip swipes, offered only where the Mac would honor them: a
    /// calendar-sourced block is read-only there, and a settled item has
    /// nothing left to apply.
    func dayPlanSwipeActions(item: DayPlanItem, model: DayPlanViewModel) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.isPending, !item.isReadOnly {
                Button {
                    Task { await model.markDone(item) }
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .tint(.green)
                Button {
                    Task { await model.skip(item) }
                } label: {
                    Label("Skip", systemImage: "slash.circle")
                }
                .tint(.gray)
            }
        }
    }
}
