import GRDB
import Observation
import os
import SwiftUI
import WatchtowerKit

/// The Inbox tab is the phone's secretary dashboard — the mobile counterpart
/// of the desktop's situation feed (`DashboardView`): a ranked list of
/// situations with a review screen per situation, not a flat signal list.
/// Member inbox items are joined in from the inbox slice via each
/// situation's publisher-embedded `signal_ids`.
@MainActor
@Observable
final class InboxViewModel {
    private(set) var situations: [Situation] = []
    /// Member-signal lookup: inbox item id → item, fed by its own observation
    /// over the inbox slice (items are informational here — bubbles in the
    /// review screen — so a separate snapshot from the situations is fine).
    private(set) var itemsByID: [Int: InboxItem] = [:]
    /// The raw overlay rows (pending + failed), observed alongside the slice.
    private(set) var pending: [PendingAction] = []
    /// Set when an enqueue/retry/dismiss write itself throws (no overlay row
    /// exists to carry the failure); rendered as a plain dismissable banner.
    private(set) var actionErrorMessage: String?

    private var situationsCancellable: AnyDatabaseCancellable?
    private var itemsCancellable: AnyDatabaseCancellable?
    private var store: ReplicaStore?
    private var outbox: ActionOutbox?
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "InboxViewModel")

    func start(store: ReplicaStore, outbox: ActionOutbox) {
        guard situationsCancellable == nil else { return }
        self.store = store
        self.outbox = outbox
        situationsCancellable = ReplicaObserver.observeWithPendingActions(
            Situation.self, kind: .situation, in: store
        ) { [weak self] situations, pending in
            // Desktop feed order: rank DESC, then most-recently-updated first.
            self?.situations = situations.sorted {
                $0.rank == $1.rank ? $0.updatedAt > $1.updatedAt : $0.rank > $1.rank
            }
            self?.pending = pending
        }
        itemsCancellable = ReplicaObserver.observe(
            InboxItem.self, kind: .inboxItem, in: store
        ) { [weak self] items in
            self?.itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The live row for a review screen; nil once the situation left the
    /// slice (closed on desktop, or this device's own action was applied).
    func situation(id: Int) -> Situation? {
        situations.first { $0.id == id }
    }

    /// The situation's member signals, oldest first (the desktop review
    /// pane's bubble order). Items missing from the inbox slice (archived,
    /// outside the slice window) are simply not shown.
    func memberSignals(of situation: Situation) -> [InboxItem] {
        situation.decodedSignalIDs
            .compactMap { itemsByID[$0] }
            .sorted { ($0.messageTS, $0.id) < ($1.messageTS, $1.id) }
    }

    // MARK: - Quick actions
    // Typed per-row methods: the ActionKind ↔ situation recordName pairing
    // lives HERE and nowhere else — same discipline as the flat-inbox
    // predecessor (no generic act-on-any-record path).

    func done(_ situation: Situation) async {
        await enqueue(.situationDone, situation: situation)
    }

    func dismiss(_ situation: Situation) async {
        await enqueue(.situationDismiss, situation: situation)
    }

    func snooze(_ situation: Situation, option: SnoozeOption, now: Date = Date()) async {
        await enqueue(
            .situationSnooze,
            situation: situation,
            params: ActionOutbox.snoozeParams(until: option.until(now: now))
        )
    }

    /// "Keep open" on a suggested resolution (DASH-07): clears the
    /// secretary's mark on the desktop, status untouched.
    func keepOpen(_ situation: Situation) async {
        await enqueue(.situationKeepOpen, situation: situation)
    }

    private func enqueue(_ kind: ActionKind, situation: Situation, params: [String: JSONValue] = [:]) async {
        guard let outbox else {
            assertionFailure("action before start(store:outbox:)")
            return
        }
        do {
            _ = try await outbox.enqueue(
                kind: kind,
                entityRecordName: SliceKind.situation.recordName(id: String(situation.id)),
                params: params
            )
        } catch {
            report(error, doing: PendingOverlay.label(of: kind))
        }
    }

    // MARK: - Overlay

    /// The pending action dimming this row (nil = render normally); chip
    /// suppression applies when the situation's status already matches.
    func chip(for situation: Situation) -> PendingAction? {
        PendingOverlay.chip(
            forRecordName: SliceKind.situation.recordName(id: String(situation.id)),
            status: situation.statusRaw,
            in: pending
        )
    }

    var failedActions: [PendingAction] {
        PendingOverlay.failed(
            in: pending,
            kinds: [.situationDone, .situationDismiss, .situationSnooze, .situationKeepOpen]
        )
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
    @State private var snoozeSituation: Situation?

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
                    ForEach(model.situations) { situation in
                        NavigationLink(value: situation.id) {
                            SituationRowView(situation: situation, isPending: model.chip(for: situation) != nil)
                        }
                        // Pending done/dismiss/snooze dim the row (overlay, not mutation).
                        .opacity(model.chip(for: situation) == nil ? 1 : 0.45)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { Task { await model.done(situation) } } label: {
                                Label("Done", systemImage: "checkmark")
                            }
                            .tint(.green)
                            Button { Task { await model.dismiss(situation) } } label: {
                                Label("Dismiss", systemImage: "xmark")
                            }
                            .tint(.gray)
                        }
                        .swipeActions(edge: .leading) {
                            Button { snoozeSituation = situation } label: {
                                Label("Snooze", systemImage: "moon.zzz")
                            }
                            .tint(.indigo)
                        }
                    }
                }
                .overlay {
                    if model.situations.isEmpty {
                        ContentUnavailableView("All clear", systemImage: "checkmark.seal")
                    }
                }
                SyncStatusFooter()
            }
            .navigationTitle("Inbox")
            .navigationDestination(for: Int.self) { id in
                SituationReviewView(situationID: id, model: model, onSnooze: { snoozeSituation = $0 })
            }
            .confirmationDialog(
                "Snooze until",
                isPresented: Binding(
                    get: { snoozeSituation != nil },
                    set: { if !$0 { snoozeSituation = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let situation = snoozeSituation {
                    ForEach(SnoozeOption.inboxCases) { option in
                        Button(option.label) { Task { await model.snooze(situation, option: option) } }
                    }
                }
            }
        }
        .onAppear { model.start(store: env.store, outbox: env.outbox) }
    }
}

// MARK: - Feed row

struct SituationRowView: View {
    let situation: Situation
    let isPending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(situation.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if !situation.summary.isEmpty {
                Text(situation.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Badge(text: situation.priority, color: priorityColor)
                if situation.hasSuggestedResolution {
                    Badge(text: "looks resolved", color: .orange)
                }
                if isPending {
                    Badge(text: "pending", color: .blue)
                }
                Spacer()
                Text(situation.lastSignalAgo)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var priorityColor: Color {
        switch situation.priority {
        case "high": return .red
        case "low": return .gray
        default: return .orange
        }
    }
}

// MARK: - Review screen

/// The phone's version of the desktop's `SituationReviewPane`: secretary
/// card (why it matters / summary / chronology), member-signal bubbles, and
/// the action bar. Reads the LIVE situation from the shared view model so a
/// desktop-side update refreshes the open screen.
struct SituationReviewView: View {
    let situationID: Int
    let model: InboxViewModel
    let onSnooze: (Situation) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let situation = model.situation(id: situationID) {
            content(situation)
        } else {
            // The situation left the slice — closed on desktop or this
            // device's own action got applied.
            ContentUnavailableView("Situation closed", systemImage: "checkmark.seal")
        }
    }

    private func content(_ situation: Situation) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(situation.title).font(.headline)
                    HStack(spacing: 6) {
                        Badge(text: situation.priority, color: situation.priority == "high" ? .red : .orange)
                        Text(situation.lastSignalAgo)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if situation.hasSuggestedResolution {
                Section("Looks resolved") {
                    Text(situation.suggestedResolution)
                        .font(.subheadline)
                    HStack(spacing: 16) {
                        Button("Done") { Task { await model.done(situation); dismiss() } }
                        Button("Keep open") { Task { await model.keepOpen(situation) } }
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }

            if !situation.whyMatters.isEmpty {
                Section("Why it matters") {
                    Text(situation.whyMatters).font(.subheadline)
                }
            }
            if !situation.summary.isEmpty {
                Section("Summary") {
                    Text(situation.summary).font(.subheadline)
                }
            }
            if !situation.chronology.isEmpty {
                Section("Chronology") {
                    Text(situation.chronology).font(.caption)
                }
            }

            let signals = model.memberSignals(of: situation)
            if !signals.isEmpty {
                Section("Signals") {
                    ForEach(signals) { item in
                        SignalBubbleView(item: item)
                    }
                }
            }
        }
        .navigationTitle("Situation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    Task { await model.done(situation); dismiss() }
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                Spacer()
                Button {
                    onSnooze(situation)
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
                Spacer()
                Button(role: .destructive) {
                    Task { await model.dismiss(situation); dismiss() }
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
            }
        }
    }
}

// MARK: - Member-signal bubble

struct SignalBubbleView: View {
    let item: InboxItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.triggerIcon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.snippet).font(.subheadline).lineLimit(4)
                HStack(spacing: 6) {
                    Badge(text: item.priority, color: item.priority == "high" ? .red : .gray)
                    if let url = URL(string: item.permalink), !item.permalink.isEmpty {
                        Link("Open", destination: url)
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding(.vertical, 2)
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
