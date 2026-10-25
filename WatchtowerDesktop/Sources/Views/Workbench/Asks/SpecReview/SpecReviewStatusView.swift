import SwiftUI
import WatchtowerCore

/// The reviewer's state where it has no findings to show yet, or where the
/// classic view is open: queued and running (a progress line), failed,
/// skipped, unreadable or unknown (the reason and **Run reviewer**), and,
/// as the classic view's banner, a finished review (**Open the reviewer's
/// findings**). `.page` fills the spec review screen; `.strip` sits above
/// the classic view.
struct SpecReviewStatusView: View {
    enum Style { case page, strip }

    let model: SpecReviewModel
    let style: Style
    var onReadSpec: (() -> Void)?
    var onOpenFindings: (() -> Void)?

    private var finished: SpecReviewResult? { SpecReviewPresentation.reviewedResult(model.row) }

    /// Failed, skipped, unreadable or unknown: the reviewer can be started again.
    private var canRun: Bool { model.row != nil && !model.isReviewerActive && finished == nil }

    private var line: String {
        if let finished { return "The reviewer has finished: \(SpecReviewPresentation.countsLine(finished))" }
        return SpecReviewPresentation.statusLine(model.row) ?? ""
    }

    var body: some View {
        switch style {
        case .page: page
        case .strip: strip
        }
    }

    private var page: some View {
        VStack(spacing: Spacing.medium) {
            if model.isReviewerActive { ProgressView().controlSize(.small) }
            Text(line).font(.callout).multilineTextAlignment(.center)
            if model.isReviewerActive {
                Text("You can read the spec the usual way meanwhile; the findings open here when it is done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: Spacing.regular) {
                if canRun { runButton }
                if let onReadSpec {
                    Button("Read the spec", action: onReadSpec).buttonStyle(.kitSecondary).controlSize(.small)
                }
            }
        }
        .frame(maxWidth: Self.pageWidth)
        .padding(Spacing.page)
    }

    private static let pageWidth: CGFloat = 420

    private var strip: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            if model.isReviewerActive {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: finished != nil ? "sparkle.magnifyingglass" : "exclamationmark.triangle")
                    .foregroundStyle(finished != nil ? Color.accentColor : Tone.warning)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(Tone.error).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.regular)
            if canRun { runButton }
            if finished != nil, let onOpenFindings {
                Button("Open the reviewer's findings", action: onOpenFindings)
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
            }
        }
        .padding(Spacing.cozy)
        .card()
    }

    private var runButton: some View {
        Button("Run reviewer") { Task { await model.runReviewer(force: true) } }
            .buttonStyle(.kitSecondary)
            .controlSize(.small)
    }
}
