import SwiftUI
import WatchtowerCore

/// A bulk press of the Inbox (Approve All, Close All…): the button, the
/// confirmation naming the count, and one result line with Try Again after a
/// partial or failed apply. The model holds the plan and the apply. A nil
/// `title` draws no button — only a press already under way or finished
/// (its spinner, its result line and Try Again), so a result outlives the
/// moment its group stops offering the press.
struct InboxBulkPressButton: View {
    let title: String?
    let confirmTitle: (Int) -> String
    @ObservedObject var model: InboxBulkPressModel

    init(title: String?, confirmTitle: @escaping (Int) -> String, model: InboxBulkPressModel) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let title {
                Button {
                    model.begin()
                } label: {
                    HStack(spacing: Spacing.compact) {
                        if isBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(title)
                    }
                }
                .buttonStyle(.kitSecondary)
                .disabled(isBusy)
            } else if isBusy {
                ProgressView().controlSize(.small)
            }
            if case .finished(let result) = model.state {
                if let line = Self.resultLine(result) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if Self.offersTryAgain(result) {
                    Button("Try Again") { model.begin() }
                        .buttonStyle(.kitQuiet)
                        .controlSize(.small)
                }
            }
        }
        .confirmationDialog(
            confirmTitle(pending?.count ?? 0),
            isPresented: Binding(
                get: { pending != nil },
                // A dismissal without a button: cancel after the press
                // that dismissed it, so a confirm is never undone (cancel
                // acts only while confirming).
                set: { shown in if !shown { Task { @MainActor in model.cancel() } } }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { plan in
            Button(confirmTitle(plan.count)) { model.confirm() }
            Button("Cancel", role: .cancel) { model.cancel() }
        }
    }

    private var isBusy: Bool {
        switch model.state {
        case .planning, .running: true
        case .idle, .confirming, .finished: false
        }
    }

    private var pending: InboxBulkPlan? {
        if case .confirming(let plan) = model.state { return plan }
        return nil
    }

    private static func offersTryAgain(_ result: InboxBulkResult) -> Bool {
        switch result {
        case .partial, .failed: true
        case .done: false
        }
    }

    /// The line under the button; nil when everything went and nothing was
    /// skipped (the list shows it).
    static func resultLine(_ result: InboxBulkResult) -> String? {
        switch result {
        case .done(0, 0):
            "Nothing left to do."
        case .done(_, 0):
            nil
        case let .done(count, skipped):
            "Done: \(count). \(skipped) were already closed."
        case let .partial(done, total, error):
            "Closed \(done) of \(total). \(error)"
        case .failed(let error):
            error
        }
    }
}
