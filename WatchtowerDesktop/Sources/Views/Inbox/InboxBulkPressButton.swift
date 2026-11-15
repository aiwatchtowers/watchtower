import SwiftUI
import WatchtowerCore

/// A bulk press of the Inbox (Approve All, Close All…): the button, the
/// confirmation naming the count, and one result line with Try Again after a
/// partial or failed apply. The model holds the plan and the apply. A nil
/// `title` draws no button — only a press already under way or finished
/// (its spinner, its result line and Try Again), so a result outlives the
/// moment its group stops offering the press.
///
/// `.inline` (a row's trailing buttons): the confirmation is the row's own
/// **Cancel** and prominent "Mark N Done" in place of the button, and the
/// result line is the row's footer (`InboxBulkPressResult`), so the
/// trailing edge never grows a line of text.
struct InboxBulkPressButton: View {
    enum Style { case header, inline }

    /// The verb of a press's result line: Mark All Done and Approve All
    /// close, Clear Old Ideas clears, Stop Tracking Quiet Ones stops.
    enum ResultCopy: Equatable {
        case closed, clearedIdeas, stoppedTracks
    }

    let title: String?
    let confirmTitle: (Int) -> String
    let style: Style
    /// Set with `resultCopy(_:)`; `.closed` by default.
    private(set) var copy = ResultCopy.closed
    @ObservedObject var model: InboxBulkPressModel

    init(title: String?, confirmTitle: @escaping (Int) -> String, model: InboxBulkPressModel, style: Style = .header) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.model = model
        self.style = style
    }

    var body: some View {
        switch style {
        case .header: header
        case .inline: inline
        }
    }

    @ViewBuilder
    private var inline: some View {
        if let pending {
            HStack(spacing: Spacing.compact) {
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.kitSecondary)
                Button(confirmTitle(pending.count)) { model.confirm() }
                    .buttonStyle(.kitPrimary)
            }
        } else if let title {
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
        }
    }

    private var header: some View {
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
            InboxBulkPressResult(model: model, copy: copy)
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

    /// The same press with `copy`'s result line.
    func resultCopy(_ copy: ResultCopy) -> Self {
        var button = self
        button.copy = copy
        return button
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

    static func offersTryAgain(_ result: InboxBulkResult) -> Bool {
        switch result {
        case .partial, .failed: true
        case .done, .unconfirmed: false
        }
    }

    /// The line under the button; nil when everything went and nothing was
    /// skipped (the list shows it). Skipped rows changed between the dry run
    /// and the apply.
    static func resultLine(_ result: InboxBulkResult, copy: ResultCopy = .closed) -> String? {
        switch result {
        case .done(0, 0):
            return "Nothing left to do."
        case .done(_, 0):
            return nil
        case let .done(count, skipped):
            switch copy {
            case .closed: return "Done: \(count). \(skipped == 1 ? "1 was" : "\(skipped) were") already closed."
            case .clearedIdeas: return "Cleared \(count). \(skipped) had changed meanwhile."
            case .stoppedTracks: return "Stopped \(count). \(skipped) had changed meanwhile."
            }
        case let .partial(done, total, error):
            switch copy {
            case .closed: return "Closed \(done) of \(total). \(error)"
            case .clearedIdeas: return "Cleared \(done) of \(total). \(error)"
            case .stoppedTracks: return "Stopped \(done) of \(total). \(error)"
            }
        case .failed(let error), .unconfirmed(let error):
            return error
        }
    }
}

/// A finished bulk press's result line and, after a partial or failed
/// apply, **Try Again** (a new dry run); nothing otherwise. `inline` (a
/// row's footer, the approved mockup): a partial or failed line in the
/// error tone with **Try Again** on the same line; a success line stays
/// secondary. The header style (Approve All) keeps its secondary line with
/// Try Again under it.
struct InboxBulkPressResult: View {
    @ObservedObject var model: InboxBulkPressModel
    var inline = false
    var copy = InboxBulkPressButton.ResultCopy.closed

    var body: some View {
        if inline, case .finished(let result) = model.state, InboxBulkPressButton.offersTryAgain(result) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                if let line = InboxBulkPressButton.resultLine(result, copy: copy) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Button("Try Again") { model.begin() }
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
            }
        } else if case .finished(let result) = model.state {
            if let line = InboxBulkPressButton.resultLine(result, copy: copy) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if InboxBulkPressButton.offersTryAgain(result) {
                Button("Try Again") { model.begin() }
                    .buttonStyle(.kitQuiet)
                    .controlSize(.small)
            }
        }
    }
}
