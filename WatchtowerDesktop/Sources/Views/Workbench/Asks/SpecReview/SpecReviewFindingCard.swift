import SwiftUI
import WatchtowerCore

/// One finding of a chapter (spec §7): its badge and text, where it comes
/// from (the owner's words only when the source is the owner's), what the
/// document says, the reviewer's note, then the mark buttons.
struct SpecReviewFindingCard: View {
    let model: SpecReviewModel
    let finding: SpecReviewChapterFinding

    var body: some View {
        let badge = SpecReviewPresentation.badge(for: finding)
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Chip(text: badge.title, color: badge.tint.color)
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
            // A finished author loop is decided on its own screen: no marks here.
            if !model.isLoop {
                SpecReviewMarkControls(model: model, key: finding.key)
            }
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

/// A caption label over a quoted line.
struct SpecReviewQuote: View {
    let label: String
    let quote: String
    var quoted = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(quoted ? "“\(quote)”" : quote)
                .font(.callout)
                .italic(quoted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
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
                        Label("Fine as is", systemImage: "checkmark.circle.fill")
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
                        Label("Fix", systemImage: "wrench.and.screwdriver.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Button("Add Comment") { startEditing() }.buttonStyle(.kitQuiet)
                        Button("Undo") { Task { await model.unmark(key) } }.buttonStyle(.kitQuiet)
                    }
                case .comment:
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Label("Your comment", systemImage: "text.bubble.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Text(model.marks[key]?.body ?? "").font(.callout).textSelection(.enabled)
                        HStack(spacing: Spacing.regular) {
                            Spacer()
                            Button("Edit") { startEditing() }.buttonStyle(.kitQuiet)
                            Button("Remove") { Task { await model.unmark(key) } }.buttonStyle(.kitQuiet)
                        }
                    }
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
