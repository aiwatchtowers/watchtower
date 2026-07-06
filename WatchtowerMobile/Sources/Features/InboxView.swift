import GRDB
import Observation
import os
import SwiftUI
import WatchtowerKit

@MainActor
@Observable
final class InboxViewModel {
    private(set) var items: [InboxItem] = []
    /// The raw overlay rows (pending + failed), observed alongside the slice.
    private(set) var pending: [PendingAction] = []
    /// Set when an enqueue/retry/dismiss write itself throws (no overlay row
    /// exists to carry the failure); rendered as a plain dismissable banner.
    private(set) var actionErrorMessage: String?

    private var cancellable: AnyDatabaseCancellable?
    private var store: ReplicaStore?
    private var outbox: ActionOutbox?
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "InboxViewModel")

    func start(store: ReplicaStore, outbox: ActionOutbox) {
        guard cancellable == nil else { return }
        self.store = store
        self.outbox = outbox
        cancellable = ReplicaObserver.observeWithPendingActions(
            InboxItem.self, kind: .inboxItem, in: store
        ) { [weak self] items, pending in
            self?.items = items.sorted { $0.priorityOrder < $1.priorityOrder }
            self?.pending = pending
        }
    }

    // MARK: - Quick actions
    // Typed per-row methods: the ActionKind ↔ inbox recordName pairing lives
    // HERE and nowhere else — there is deliberately no generic
    // act-on-any-record path (Task 3 review note).

    func resolve(_ item: InboxItem) async {
        await enqueue(.inboxResolve, item: item)
    }

    func dismiss(_ item: InboxItem) async {
        await enqueue(.inboxDismiss, item: item)
    }

    func snooze(_ item: InboxItem, option: SnoozeOption, now: Date = Date()) async {
        await enqueue(.inboxSnooze, item: item, params: ActionOutbox.snoozeParams(until: option.until(now: now)))
    }

    private func enqueue(_ kind: ActionKind, item: InboxItem, params: [String: JSONValue] = [:]) async {
        guard let outbox else {
            assertionFailure("action before start(store:outbox:)")
            return
        }
        do {
            _ = try await outbox.enqueue(
                kind: kind,
                entityRecordName: SliceKind.inboxItem.recordName(id: String(item.id)),
                params: params
            )
        } catch {
            report(error, doing: PendingOverlay.label(of: kind))
        }
    }

    // MARK: - Overlay

    /// The pending action dimming this row (nil = render normally); chip
    /// suppression applies when the item's status already matches.
    func chip(for item: InboxItem) -> PendingAction? {
        PendingOverlay.chip(
            forRecordName: SliceKind.inboxItem.recordName(id: String(item.id)),
            status: item.status,
            in: pending
        )
    }

    var failedActions: [PendingAction] {
        PendingOverlay.failed(in: pending, kinds: [.inboxResolve, .inboxDismiss, .inboxSnooze])
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

struct InboxView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = InboxViewModel()
    @State private var snoozeItem: InboxItem?

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
                    ForEach(model.items) { item in
                        row(item)
                    }
                }
                .overlay { if model.items.isEmpty { ContentUnavailableView("Inbox empty", systemImage: "tray") } }
                SyncStatusFooter()
            }
            .navigationTitle("Inbox")
            .confirmationDialog(
                "Snooze until",
                isPresented: Binding(
                    get: { snoozeItem != nil },
                    set: { if !$0 { snoozeItem = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let item = snoozeItem {
                    ForEach(SnoozeOption.inboxCases) { option in
                        Button(option.label) { Task { await model.snooze(item, option: option) } }
                    }
                }
            }
        }
        .onAppear { model.start(store: env.store, outbox: env.outbox) }
    }

    @ViewBuilder
    private func row(_ item: InboxItem) -> some View {
        let chip = model.chip(for: item)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.triggerIcon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.snippet).font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    Badge(text: item.status, color: .gray)
                    Badge(text: item.priority, color: color(item.priorityColor))
                    if chip != nil { Badge(text: "pending", color: .blue) }
                }
            }
        }
        .padding(.vertical, 2)
        // Pending resolve/dismiss/snooze dim the row (overlay, not mutation).
        .opacity(chip == nil ? 1 : 0.45)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { Task { await model.resolve(item) } } label: {
                Label("Resolve", systemImage: "checkmark")
            }
            .tint(.green)
            Button { Task { await model.dismiss(item) } } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .tint(.gray)
        }
        .swipeActions(edge: .leading) {
            Button { snoozeItem = item } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
            .tint(.indigo)
        }
    }
}

// MARK: - Enqueue-error row (shared by Inbox and Tasks)

/// A write into the outbox itself failed — there is no overlay row to retry,
/// so this is a plain message with an OK to clear it.
struct ActionErrorRow: View {
    let message: String
    let onClear: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button("OK", action: onClear)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
    }
}
