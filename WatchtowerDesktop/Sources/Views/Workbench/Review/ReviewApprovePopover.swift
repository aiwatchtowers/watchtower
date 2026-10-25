import SwiftUI
import WatchtowerCore

/// The text behind Approve (#964, spec §6): the confirmation's title, next
/// step and warnings, the button, the closed round's outcome and the
/// banner after Approve. Views stay thin; the tests pin these.
enum ReviewApprovePresentation {
    static func title(branch: String) -> String {
        branch.isEmpty ? "Approve this branch?" : "Approve \(branch)?"
    }

    static func nextStep(roundID: Int64) -> String {
        "The agent gets the line “Review round #\(roundID) approved” and finishes the branch the way its methodology says: "
            + "PR and merge, targets to done, finish_session."
    }

    /// `Approve`, or `Resolve N and approve` when earlier comments are still open.
    static func buttonTitle(openEarlier: Int) -> String {
        openEarlier > 0 ? "Resolve \(openEarlier) and approve" : "Approve"
    }

    /// What is unfinished; it only warns. Chapters not viewed (count and
    /// lines; lines alone without chapters), then Wrap-up items marked
    /// Partly or Not done.
    @MainActor static func warnings(_ model: ReviewChangesModel) -> [String] {
        var out: [String] = []
        let progress = model.progress
        let lines = progress.totalLines - progress.viewedLines
        let chapters = progress.chapterCount - progress.chaptersDone
        if chapters > 0 {
            out.append("Not viewed: \(count(chapters, "chapter")) (\(count(lines, "line")))")
        } else if lines > 0 {
            out.append("Not viewed: \(count(lines, "line"))")
        }
        for item in model.intentItems {
            let state = model.checks.first {
                $0.chapterKey == ReviewChangesModel.wrapupChapter && $0.lens == ReviewChangesModel.intentLens
                    && $0.itemKey == item.key
            }?.state
            switch state {
            case .partial: out.append("Wrap-up: \(item.text) — marked Partly")
            case .notDone: out.append("Wrap-up: \(item.text) — marked Not done")
            default: break
            }
        }
        return out
    }

    /// One open earlier comment: where it sits, its first line, outdated marked.
    static func earlierLine(_ comment: ReviewComment) -> String {
        let place: String
        if let path = comment.path {
            let lines = comment.startLine == comment.endLine ? "\(comment.startLine)" : "\(comment.startLine)–\(comment.endLine)"
            place = "\(path):\(lines)"
        } else {
            place = "Design"
        }
        let first = ReviewPresentation.firstLine(comment.body)
        return "\(place) — \(first)" + (comment.status == .outdated ? " (outdated)" : "")
    }

    /// A closed round's outcome in the toolbar; nil when Go's answer did not say.
    static func outcomeText(_ outcome: String?) -> String? {
        switch outcome {
        case ReviewOutcome.approved: "Approved"
        case ReviewOutcome.changes: "Changes requested"
        default: nil
        }
    }

    /// The banner's delivery part, and whether Open Workchat applies: only
    /// when the line reached the session.
    static func delivery(_ delivery: SessionLineDelivery.Delivery?) -> (text: String, reached: Bool) {
        switch delivery {
        case .submitted: ("the agent got the line", true)
        case .typed: ("line pasted — press Return in the terminal", true)
        case .copied: ("copied — paste it into the terminal", false)
        case .queued: ("the agent gets the line next", false)
        case .held, .noSession, nil: ("the agent will see it in its next brief", false)
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

/// The toolbar's Approve (#964): off with drafts or without a session (its
/// help says why); a press asks first in the confirmation popover.
struct ReviewApproveButton: View {
    let model: ReviewChangesModel
    let branch: String
    /// The toolbar's one prominent verdict (`ReviewToolbar.prominentVerdict`).
    var prominent = true
    @State private var confirming = false

    var body: some View {
        Button("Approve") { confirming = true }
            .verdictStyle(prominent: prominent)
            .disabled(!ReviewToolbar.canApprove(model))
            .help(model.approvalBlocker ?? "Close the review as approved; the agent finishes the branch")
            .popover(isPresented: $confirming, arrowEdge: .bottom) {
                ReviewApprovePopover(model: model, branch: branch) { confirming = false }
            }
    }
}

extension View {
    /// A verdict button: the prominent one is `.kitPrimary`, the other `.kitSecondary`.
    @ViewBuilder func verdictStyle(prominent: Bool) -> some View {
        if prominent { buttonStyle(.kitPrimary) } else { buttonStyle(.kitSecondary) }
    }
}

/// Approve's confirmation (spec §6, mockup 3): what happens next, what is
/// unfinished, and the open comments of earlier rounds, which the button
/// resolves — they never vanish unseen (REVIEW-03).
struct ReviewApprovePopover: View {
    let model: ReviewChangesModel
    let branch: String
    let dismiss: () -> Void

    var body: some View {
        let earlier = model.openEarlierComments
        let warnings = ReviewApprovePresentation.warnings(model)
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(ReviewApprovePresentation.title(branch: branch)).font(.headline)
            Text(ReviewApprovePresentation.nextStep(roundID: model.round?.id ?? 0))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ForEach(warnings, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(WarningLabelStyle())
                    }
                }
                .padding(Spacing.cozy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            if !earlier.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("Open comments from earlier rounds — approving resolves them")
                        .font(.caption.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            ForEach(earlier) { comment in
                                Text(ReviewApprovePresentation.earlierLine(comment))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button("Cancel", action: dismiss)
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(ReviewApprovePresentation.buttonTitle(openEarlier: earlier.count)) {
                    dismiss()
                    Task { await model.approve(resolveOpen: !earlier.isEmpty) }
                }
                .buttonStyle(.kitPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!ReviewToolbar.canApprove(model))
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(Spacing.large)
        .frame(width: 400)
        .popoverSurface()
    }
}

/// A warning line: the triangle in the warning tone, the text as it is.
private struct WarningLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            configuration.icon.foregroundStyle(Tone.warning)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// After Approve (spec §6): "Approved HH:MM · round N closed" and what
/// happened to the line; Open Workchat only when the line reached the
/// session. The pane stays read-only.
struct ReviewApprovedBanner: View {
    let model: ReviewChangesModel
    /// nil = the session is gone or has no Workchat to open.
    var openWorkchat: (() -> Void)?

    var body: some View {
        let delivery = ReviewApprovePresentation.delivery(model.lastSend)
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.compact) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Tone.success)
                Text(approvedTitle).fontWeight(.semibold)
                Text("round \(model.round?.id ?? 0) closed · \(delivery.text)")
                Spacer(minLength: Spacing.small)
                if delivery.reached, let openWorkchat {
                    Button("Open Workchat", action: openWorkchat).buttonStyle(.kitQuiet)
                }
            }
            Text("The review is read-only. If the agent changes code, Review on the session strip opens a new round.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tone.success.opacity(Fill.selectedOpacity))
    }

    private var approvedTitle: String {
        guard let at = model.approvedAt else { return "Approved" }
        return "Approved \(at.formatted(date: .omitted, time: .shortened))"
    }
}
