import SwiftUI
import WatchtowerSync

/// The Not delivered list (relay client mockup 5a), pushed from Now: the footer naming the Mac, one card per action
/// that never reached it (summary, time and why, a failed retry's message, Retry), then a destructive Dismiss All
/// behind a confirmation. Rows follow the replica; the list pops back to Now when it empties.
struct NotDeliveredView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var retrying: Set<String>
    @State private var errors: [String: String]
    @State private var confirming: Bool
    @State private var dismissError: String?

    /// The screenshot tour opens it confirming, or with a retry running over a failed one; the app passes nothing.
    init(confirming: Bool = false, retrying: Set<String> = [], errors: [String: String] = [:]) {
        _confirming = State(initialValue: confirming)
        _retrying = State(initialValue: retrying)
        _errors = State(initialValue: errors)
    }

    var body: some View {
        // As on Now: "Today 09:58" turns into "Yesterday 09:58" by the clock alone.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(model(at: context.date))
        }
        .background(Color(.systemBackground))
        .navigationTitle(NotDeliveredModel.title)
        .onChange(of: isEmpty, initial: true) { _, empty in
            if empty { dismiss() }
        }
    }

    /// The list empties when the replica's last Not delivered row goes (a Retry, Dismiss All, another device).
    private var isEmpty: Bool {
        OutboxItem.rows(env.workbenchReplica.snapshot.pending, .undelivered).isEmpty
    }

    private func model(at date: Date) -> NotDeliveredModel {
        let snapshot = env.workbenchReplica.snapshot
        return NotDeliveredModel(
            items: OutboxItem.rows(snapshot.pending, .undelivered), snapshot: snapshot,
            macName: snapshot.heartbeat?.macName ?? "", now: date, calendar: .current,
            retrying: retrying, errors: errors)
    }

    private func content(_ model: NotDeliveredModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Text(model.footer)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.small)
                ForEach(model.rows) { row in
                    NotDeliveredRowView(row: row) { retry(row.id) }
                }
                dismissAll(model)
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.large)
        }
    }

    private func dismissAll(_ model: NotDeliveredModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Button { confirming = true } label: {
                Text(NotDeliveredModel.dismissAllTitle)
                    .font(TypeScale.rowTitle)
                    .foregroundStyle(PhoneTone.red.color)
                    .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .card(padding: EdgeInsets(top: Spacing.tight, leading: Spacing.medium, bottom: Spacing.tight, trailing: Spacing.medium))
            // Anchored on the button, so the confirmation opens over it.
            .confirmationDialog(model.confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button(NotDeliveredModel.dismissAllTitle, role: .destructive) { dismissAllNow() }
            }
            if let dismissError {
                Text(dismissError)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.small)
            }
        }
        .padding(.top, Spacing.regular)
    }

    /// Retry through the outbox; the row's button is off while it runs, and a failure's message stays under the
    /// row until the next attempt ends.
    private func retry(_ id: String) {
        guard !retrying.contains(id) else { return }
        retrying.insert(id)
        let session = env.activeSession
        Task {
            do {
                try await session.retry(actionID: id)
                errors[id] = nil
            } catch {
                errors[id] = NotDeliveredModel.retryErrorText(error)
            }
            retrying.remove(id)
        }
    }

    private func dismissAllNow() {
        do {
            try env.activeSession.dismissAllUndelivered()
            dismissError = nil
        } catch {
            dismissError = NotDeliveredModel.dismissErrorText
        }
    }
}

/// One Not delivered card: the summary, "Today 09:58 · No answer from …", a failed retry's message, and Retry.
private struct NotDeliveredRowView: View {
    let row: NotDeliveredRow
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(row.summary).font(TypeScale.rowTitle)
                Text(row.detail).font(TypeScale.meta).foregroundStyle(.secondary)
                if let error = row.error {
                    Text(error).font(TypeScale.meta).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Spacing.medium)
            Button(NotDeliveredModel.retryTitle, action: onRetry)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(row.isRetrying ? PhoneTone.secondary.color : PhoneTone.accent.color)
                .buttonStyle(.plain)
                .frame(minHeight: PhoneMetrics.minTouch)
                .disabled(row.isRetrying)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
