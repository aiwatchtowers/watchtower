import SwiftUI
import WatchtowerCore

/// One finding of a chapter (spec §7): its badge and text, where it comes
/// from (the owner's words only when the source is the owner's), what the
/// document says, the reviewer's note, then the mark buttons.
struct SpecReviewFindingCard: View {
    let model: SpecReviewModel
    let finding: SpecReviewChapterFinding

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                SpecReviewChips(severity: finding.severity, kind: SpecReviewPresentation.badge(for: finding))
                Text(text).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let source, !source.quote.isEmpty {
                SpecReviewQuote(label: SpecReviewPresentation.sourceLabel(source), quote: source.quote)
            }
            if let anchor, !anchor.quote.isEmpty {
                SpecReviewQuote(label: anchor.heading.isEmpty ? "The document says" : "The document says · \(anchor.heading)",
                                quote: anchor.quote)
            }
            if !note.isEmpty {
                SpecReviewQuote(label: "Reviewer", quote: note, quoted: false)
            }
            if case let .blindSpot(spot) = finding, let evidence = spot.evidence, !evidence.path.isEmpty {
                Text(evidence.line > 0 ? "\(evidence.path):\(evidence.line)" : evidence.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            // A finished author loop takes Fix and Comment only: the sides
            // are picked on Decide (spec 2026-10-28 §4).
            SpecReviewMarkControls(model: model, key: finding.key, commentOnly: model.isLoop)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var text: String {
        switch finding {
        case let .agreement(f): f.text
        case let .decidedAlone(f): f.text
        case let .blindSpot(f): f.text
        }
    }

    private var source: SpecReviewResult.Source? {
        if case let .agreement(f) = finding { return f.source }
        return nil
    }

    private var anchor: SpecReviewResult.Anchor? {
        switch finding {
        case let .agreement(f): f.anchor
        case let .decidedAlone(f): f.anchor
        case let .blindSpot(f): f.anchor
        }
    }

    private var note: String {
        switch finding {
        case let .agreement(f): f.note
        case let .decidedAlone(f): f.note
        case let .blindSpot(f): f.why
        }
    }
}

/// A label over a quote: upright text in the primary colour with a bar on
/// its left, inline Markdown rendered (code spans, emphasis; links as text), so it reads
/// at a glance in dark mode (spec 2026-10-28 §3). `quoted` marks words
/// copied from a source (the bar is drawn); the reviewer's and the author's
/// own lines go without it.
struct SpecReviewQuote: View {
    let label: String
    let quote: String
    var quoted = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            HStack(alignment: .top, spacing: Spacing.compact) {
                if quoted {
                    Rectangle().fill(.secondary).frame(width: Spacing.tight)
                }
                Text(MarkdownView.inlineLabel(quote))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A finding's head chips: the coloured severity, when the reviewer gave
/// one, then the neutral kind (and loop status).
struct SpecReviewChips: View {
    let severity: SpecReviewSeverity?
    let kind: SpecReviewPresentation.Badge

    var body: some View {
        if let badge = SpecReviewPresentation.severityBadge(severity) {
            Chip(text: badge.title, color: badge.tint.color)
        }
        Chip(text: kind.title, color: kind.tint.color)
    }
}

/// The owner's pick on a finding, in the primary colour: only severity is
/// coloured on this screen.
struct SpecReviewPickedLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
    }
}

/// The comment under a picked **Fix** / **Reviewer is right**: the owner's
/// words with **Edit**, or **Add comment**; it writes the body of the same
/// `comment` mark (spec 2026-10-28 §4).
struct SpecReviewMarkComment: View {
    let model: SpecReviewModel
    let key: String
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        let body = model.marks[key]?.body ?? ""
        if editing {
            VStack(alignment: .leading, spacing: Spacing.small) {
                CommentTextEditor(
                    text: $text,
                    placeholder: "Your comment for the author",
                    focusOnAppear: true,
                    minHeight: CommentTextEditor.formMinHeight,
                    maxHeight: CommentTextEditor.formMaxHeight,
                    onSubmit: save
                ) { editing = false }
                HStack(spacing: Spacing.regular) {
                    Spacer()
                    Button("Cancel") { editing = false }.buttonStyle(.kitQuiet)
                    Button("Save", action: save)
                        .buttonStyle(.kitSecondary)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Shortcut: ⌘↩")
                }
            }
        } else if body.isEmpty {
            HStack {
                Spacer()
                Button("Add Comment") { text = ""; editing = true }.buttonStyle(.kitQuiet)
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(body).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Edit") { text = body; editing = true }.buttonStyle(.kitQuiet)
                }
            }
        }
    }

    private func save() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        editing = false
        Task { await model.mark(key, .comment, body: body) }
    }
}

/// The owner's mark on one finding: **Fix**, **Fine as is**, **Comment** and
/// **Not useful** while unmarked; the mark with Undo, or the comment with Edit
/// and Remove, once marked. **Fix** is a comment with no words of the owner's:
/// the finding goes to the author as it is (`SpecReviewAnswer`). A comment is
/// written in place (⌘↩ saves, Esc cancels).
struct SpecReviewMarkControls: View {
    let model: SpecReviewModel
    let key: String
    /// A finished author loop: **Fix** and **Comment** only.
    var commentOnly = false
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        Group {
            if editing {
                editor
            } else {
                switch model.marks[key]?.state {
                case .ok:
                    HStack(spacing: Spacing.regular) {
                        // In a loop the mark comes from Decide's Author is right / Skip.
                        Label(commentOnly ? "Kept as is" : "Fine as is", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Tone.success)
                        Spacer()
                        Button("Undo") { Task { await model.unmark(key) } }.buttonStyle(.kitQuiet)
                    }
                case .notUseful:
                    HStack(spacing: Spacing.regular) {
                        Label("Not useful", systemImage: "hand.thumbsdown.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.secondary)
                        Spacer()
                        Button("Undo") { Task { await model.unmark(key) } }.buttonStyle(.kitQuiet)
                    }
                case .comment where model.marks[key]?.body.isEmpty ?? true:
                    HStack(spacing: Spacing.regular) {
                        SpecReviewPickedLabel(title: "Fix", systemImage: "wrench.and.screwdriver.fill")
                        Spacer()
                        Button("Add Comment") { startEditing() }.buttonStyle(.kitQuiet)
                        Button("Undo") { Task { await model.unmark(key) } }.buttonStyle(.kitQuiet)
                    }
                case .comment:
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        SpecReviewPickedLabel(title: "Your comment", systemImage: "text.bubble.fill")
                        Text(model.marks[key]?.body ?? "").font(.callout).textSelection(.enabled)
                        HStack(spacing: Spacing.regular) {
                            Spacer()
                            Button("Edit") { startEditing() }.buttonStyle(.kitQuiet)
                            Button("Remove") { Task { await model.unmark(key) } }.buttonStyle(.kitQuiet)
                        }
                    }
                case .viewed where commentOnly, nil where commentOnly:
                    HStack(spacing: Spacing.regular) { fixButton; commentButton }
                case .viewed, nil:
                    // A narrow drawer puts them on two rows.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.regular) { markButtons }
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            HStack(spacing: Spacing.regular) { fixButton; fineButton }
                            HStack(spacing: Spacing.regular) { commentButton; notUsefulButton }
                        }
                    }
                }
            }
        }
        .controlSize(.small)
        .disabled(model.isAnswering)
    }

    @ViewBuilder
    private var markButtons: some View {
        fixButton
        fineButton
        commentButton
        notUsefulButton
    }

    private var fixButton: some View {
        Button("Fix") { Task { await model.mark(key, .comment) } }
            .buttonStyle(.kitSecondary)
            .help("The reviewer is right: send this finding to the author as it is")
    }

    private var fineButton: some View {
        Button("Fine as is") { Task { await model.mark(key, .ok) } }.buttonStyle(.kitSecondary)
    }

    private var commentButton: some View {
        Button("Comment") { startEditing() }.buttonStyle(.kitSecondary)
    }

    private var notUsefulButton: some View {
        Button("Not useful") { Task { await model.mark(key, .notUseful) } }.buttonStyle(.kitSecondary)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            CommentTextEditor(
                text: $text,
                placeholder: "Your comment for the author",
                focusOnAppear: true,
                minHeight: CommentTextEditor.formMinHeight,
                maxHeight: CommentTextEditor.formMaxHeight,
                onSubmit: save,
                onCancel: cancelEditing
            )
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button("Cancel") { editing = false }.buttonStyle(.kitQuiet)
                Button("Save", action: save)
                    .buttonStyle(.kitSecondary)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Shortcut: ⌘↩")
            }
        }
    }

    private func cancelEditing() {
        editing = false
    }

    private func startEditing() {
        text = model.marks[key]?.state == .comment ? model.marks[key]?.body ?? "" : ""
        editing = true
    }

    private func save() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        editing = false
        Task { await model.mark(key, .comment, body: body) }
    }
}
