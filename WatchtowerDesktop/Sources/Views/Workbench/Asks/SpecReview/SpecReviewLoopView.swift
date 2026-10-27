import SwiftUI
import WatchtowerCore

/// A finished reviewer↔author loop, the owner's turn (spec 2026-10-26 §6):
/// why the loop ended early when it did, **Disputed** on top — each card
/// with **Reviewer is right** / **Author is right** and an optional
/// comment —, **Not answered by the author** (findings the loop ended on:
/// **Fix** / **Skip**), **Fixed by the author** folded with **Reopen**, then the note
/// and a one-press **Approve** (it asks once only after an early end with
/// a dispute nobody answered). The answer is always `approved`; the
/// **Reviewer is right** and **Reopen** marks go with it as comments.
struct SpecReviewLoopView: View {
    let model: SpecReviewModel
    @State private var confirmingApprove = false
    @State private var fixesExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                if let line = model.row.flatMap(SpecReviewLoop.endLine) {
                    Label(line, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Tone.warning)
                        .padding(Spacing.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }
                if model.row?.loopUnreadable == true {
                    Text("Part of the loop's history could not be read.")
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                }
                disputed
                unanswered
                fixed
                CommentTextEditor(
                    text: Binding(get: { model.note }, set: { model.note = $0 }),
                    placeholder: "Note for the author (optional)",
                    minHeight: CommentTextEditor.formMinHeight,
                    maxHeight: CommentTextEditor.formMaxHeight
                )
                actions
            }
            .frame(maxWidth: ReadableColumn.maxLineWidth, alignment: .leading)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(model.approveConfirmMessage, isPresented: $confirmingApprove) {
            Button("Approve") { approve() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            // A fix the owner already reopened stays in view.
            if model.fixes.contains(where: { model.marks[$0.item.key]?.state == .comment }) { fixesExpanded = true }
        }
    }

    @ViewBuilder
    private var disputed: some View {
        let disputes = model.disputes
        VStack(alignment: .leading, spacing: Spacing.regular) {
            SectionHeader(title: "Disputed", systemImage: "exclamationmark.bubble", count: disputes.count)
            if disputes.isEmpty {
                Text(model.unanswered.isEmpty
                     ? "Nothing is disputed: the reviewer and the author settled every finding."
                     : "Nothing is disputed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Pick a side on each. One you leave counts as Author is right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(disputes, id: \.item.key) { SpecReviewDisputeCard(model: model, entry: $0) }
            }
        }
    }

    @ViewBuilder
    private var unanswered: some View {
        let items = model.unanswered
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                SectionHeader(title: "Not answered by the author", systemImage: "questionmark.bubble", count: items.count)
                Text("The loop ended before the author answered these (or before the reviewer checked the fix). " +
                     "Nobody argued over them. One you leave counts as Skip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(items, id: \.item.key) { SpecReviewDisputeCard(model: model, entry: $0, unanswered: true) }
            }
        }
    }

    @ViewBuilder
    private var fixed: some View {
        let fixes = model.fixes
        if !fixes.isEmpty {
            DisclosureGroup(isExpanded: $fixesExpanded) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ForEach(fixes, id: \.item.key) { SpecReviewFixRow(model: model, entry: $0) }
                }
                .padding(.top, Spacing.small)
            } label: {
                SectionHeader(title: "Fixed by the author", systemImage: "checkmark.seal", count: fixes.count)
            }
        }
    }

    private var actions: some View {
        let blocker = model.answerBlocker
        return VStack(alignment: .trailing, spacing: Spacing.small) {
            if let blocker {
                HStack(spacing: Spacing.compact) {
                    Text(blocker).font(.caption).foregroundStyle(Tone.warning)
                    if SpecReviewPresentation.showsGoToMeaning(row: model.row, hasQuestions: model.hasQuestions) {
                        Button("Go to Meaning") { model.phase = .meaning }.buttonStyle(.kitQuiet)
                    }
                }
            }
            HStack(spacing: Spacing.regular) {
                if model.isAnswering { ProgressView().controlSize(.small) }
                Spacer()
                Button("Approve", action: pressApprove)
                    .buttonStyle(.kitPrimary)
                    .help("Approve the document; Reviewer is right and Reopen go to the author as fixes to make")
            }
            .disabled(blocker != nil || model.isAnswering)
        }
        .controlSize(.small)
    }

    private func pressApprove() {
        if model.needsApproveConfirm { confirmingApprove = true } else { approve() }
    }

    // The answer's failures land in the ask's answer errors (the drawer's footer).
    private func approve() {
        Task { _ = await model.approve() }
    }
}

/// One dispute: the finding, where the document says it, the reviewer's
/// argument, the author's reason, why it is still open, then the owner's
/// pick. An unanswered one picks **Fix** / **Skip** (the same marks).
private struct SpecReviewDisputeCard: View {
    let model: SpecReviewModel
    let entry: SpecReviewLedgerEntry
    var unanswered = false
    @State private var comment = ""

    var body: some View {
        let badge = SpecReviewPresentation.disputeBadge(entry)
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Chip(text: badge.title, color: badge.tint.color)
                Text(entry.item.text).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let anchor = entry.item.anchor, !anchor.quote.isEmpty {
                SpecReviewQuote(label: anchor.heading.isEmpty ? "The document says" : "The document says · \(anchor.heading)",
                                quote: anchor.quote)
            }
            if let position = SpecReviewPresentation.reviewerPosition(entry) {
                SpecReviewQuote(label: "Reviewer", quote: position, quoted: false)
            }
            if let reason = SpecReviewPresentation.authorReason(entry) {
                SpecReviewQuote(label: "Author", quote: reason, quoted: false)
            }
            if let status = SpecReviewPresentation.loopStatus(entry) {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            pick
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private var pick: some View {
        let key = entry.item.key
        Group {
            switch model.marks[key]?.state {
            case .comment:
                VStack(alignment: .leading, spacing: Spacing.small) {
                    HStack(spacing: Spacing.regular) {
                        Label(unanswered ? "Fix — the author fixes it" : "Reviewer is right — the author fixes it",
                              systemImage: "text.bubble.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Button("Undo") { Task { await model.unmark(key) } }.buttonStyle(.kitQuiet)
                    }
                    if let body = model.marks[key]?.body, !body.isEmpty {
                        Text(body).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .ok:
                HStack(spacing: Spacing.regular) {
                    Label(unanswered ? "Skip — the document stays" : "Author is right — the document stays",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Tone.success)
                    Spacer()
                    Button("Undo") { Task { await model.unmark(key) } }.buttonStyle(.kitQuiet)
                }
            case .notUseful:
                // Marked on the findings screen; never sent to the author
                // (SpecReviewAnswer sends comment marks only).
                HStack(spacing: Spacing.regular) {
                    Label("Not useful", systemImage: "hand.thumbsdown.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    Button("Undo") { Task { await model.unmark(key) } }.buttonStyle(.kitQuiet)
                }
            case .viewed, nil:
                VStack(alignment: .leading, spacing: Spacing.small) {
                    CommentTextEditor(
                        text: $comment,
                        placeholder: unanswered ? "Comment for the author (optional, goes with Fix)"
                            : "Comment for the author (optional, goes with Reviewer is right)",
                        minHeight: CommentTextEditor.formMinHeight,
                        maxHeight: CommentTextEditor.formMaxHeight
                    )
                    HStack(spacing: Spacing.regular) {
                        Button(unanswered ? "Fix" : "Reviewer is right") {
                            Task { await model.pick(key, reviewerRight: true, body: comment) }
                        }
                        .buttonStyle(.kitSecondary)
                        .help("The author must fix it")
                        Button(unanswered ? "Skip" : "Author is right") {
                            Task { await model.pick(key, reviewerRight: false) }
                        }
                        .buttonStyle(.kitSecondary)
                        .help("Keep the document as it is")
                    }
                }
            }
        }
        .controlSize(.small)
        .disabled(model.isAnswering)
    }
}

/// One fix the reviewer confirmed: the finding, its round, the author's
/// note, and **Reopen** (a comment the owner must write).
private struct SpecReviewFixRow: View {
    let model: SpecReviewModel
    let entry: SpecReviewLedgerEntry
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        let key = entry.item.key
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Text(entry.item.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.regular)
                Text(SpecReviewPresentation.fixRound(entry)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            let note = SpecReviewPresentation.fixNote(entry)
            Text(note)
                .font(.caption)
                .foregroundStyle(SpecReviewPresentation.authorReason(entry) == nil ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if editing {
                editor
            } else if model.marks[key]?.state == .comment {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    HStack(spacing: Spacing.regular) {
                        Label("Reopened", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Button("Undo") { Task { await model.unmark(key) } }.buttonStyle(.kitQuiet)
                    }
                    Text(model.marks[key]?.body ?? "")
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Reopen") { text = ""; editing = true }
                        .buttonStyle(.kitQuiet)
                        .help("Send it back to the author with your comment")
                }
            }
        }
        .controlSize(.small)
        .disabled(model.isAnswering)
        .padding(Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            CommentTextEditor(
                text: $text,
                placeholder: "What is wrong with the fix?",
                focusOnAppear: true,
                minHeight: CommentTextEditor.formMinHeight,
                maxHeight: CommentTextEditor.formMaxHeight,
                onSubmit: save
            ) { editing = false }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button("Cancel") { editing = false }.buttonStyle(.kitQuiet)
                Button("Reopen", action: save)
                    .buttonStyle(.kitSecondary)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Shortcut: ⌘↩")
            }
        }
    }

    private func save() {
        let body = text
        let key = entry.item.key
        Task { if await model.reopen(key, body: body) { editing = false } }
    }
}
