import SwiftUI
import WatchtowerCore

/// One finding of a chapter (spec §7): its badge and text, where it comes
/// from (the owner's words only when the source is the owner's), what the
/// document says, the reviewer's note, then the buttons its kind offers
/// (spec 2026-11-08 §2) and its Discuss thread, open or folded.
struct SpecReviewFindingCard: View {
    let model: SpecReviewModel
    let finding: SpecReviewChapterFinding
    @State private var thread = SpecReviewThreadVisibility.auto
    @Environment(\.specReviewThreads) private var threads

    var body: some View {
        let kind = SpecReviewPresentation.cardKind(for: finding)
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                SpecReviewChips(
                    severity: finding.severity,
                    kind: SpecReviewPresentation.badge(for: finding),
                    origin: kind == .fromDiscussion ? SpecReviewPresentation.fromDiscussionBadge : nil
                )
                Text(text).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let source, !source.quote.isEmpty {
                SpecReviewQuote(label: source.label, quote: source.quote)
            }
            if let anchor, !anchor.quote.isEmpty {
                SpecReviewQuote(label: anchor.heading.isEmpty ? "The document says" : "The document says · \(anchor.heading)",
                                quote: anchor.quote)
            }
            if !note.text.isEmpty {
                SpecReviewQuote(label: note.label, quote: note.text, quoted: false)
            }
            if case let .blindSpot(spot) = finding, let evidence = spot.evidence, !evidence.path.isEmpty {
                Text(evidence.line > 0 ? "\(evidence.path):\(evidence.line)" : evidence.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            // A finished author loop takes Fix and Discuss (or Comment)
            // only: the sides are picked on Decide (spec 2026-10-28 §4).
            SpecReviewMarkControls(
                model: model,
                key: finding.key,
                kind: kind,
                commentOnly: model.isLoop,
                onDiscuss: threads == nil ? nil : { thread = .shown }
            )
            SpecReviewCardThreadSection(key: finding.key, visibility: $thread)
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
        case let .fromDiscussion(f): f.headline
        }
    }

    /// Where it comes from, labelled: an agreement's source, or the owner's
    /// own words a thread finding quotes (its document quote is the anchor's).
    private var source: (label: String, quote: String)? {
        switch finding {
        case let .agreement(f): f.source.map { (SpecReviewPresentation.sourceLabel($0), $0.quote) }
        case let .fromDiscussion(f) where f.quote.source == "thread": ("What you said in the discussion", f.quote.text)
        default: nil
        }
    }

    private var anchor: SpecReviewResult.Anchor? {
        switch finding {
        case let .agreement(f): f.anchor
        case let .decidedAlone(f): f.anchor
        case let .blindSpot(f): f.anchor
        case let .fromDiscussion(f): f.anchor
        }
    }

    /// The reviewer's note, or the text of a finding the assistant wrote
    /// in a thread (its title heads the card).
    private var note: (label: String, text: String) {
        switch finding {
        case let .agreement(f): ("Reviewer", f.note)
        case let .decidedAlone(f): ("Reviewer", f.note)
        case let .blindSpot(f): ("Reviewer", f.why)
        case let .fromDiscussion(f): ("Assistant", f.title.isEmpty ? "" : f.text)
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
/// one, then the neutral kind (and loop status), then where it came from
/// (**From discussion**).
struct SpecReviewChips: View {
    let severity: SpecReviewSeverity?
    let kind: SpecReviewPresentation.Badge
    var origin: SpecReviewPresentation.Badge?

    var body: some View {
        if let badge = SpecReviewPresentation.severityBadge(severity) {
            Chip(text: badge.title, color: badge.tint.color)
        }
        Chip(text: kind.title, color: kind.tint.color)
        if let origin {
            Chip(text: origin.title, color: origin.tint.color)
        }
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

/// The owner's mark on one finding: the buttons its kind offers while
/// unmarked (`SpecReviewCardActions`: **Fix**, **Skip**, **Checked**,
/// **Discuss**, **Not useful**); the mark with Undo, or the comment with Edit
/// and Remove, once marked. **Fix** is a comment with no words of the owner's:
/// the finding goes to the author as it is (`SpecReviewAnswer`); a picked Fix
/// keeps **Add Comment** for a one-line note. **Skip** and **Checked** are the
/// one `ok` mark. Where the screen has no threads, **Comment** stands in
/// **Discuss**'s place. A comment is written in place (⌘↩ saves, Esc cancels).
struct SpecReviewMarkControls: View {
    let model: SpecReviewModel
    let key: String
    var kind: SpecReviewCardKind = .actionable
    /// A finished author loop: **Fix** and **Discuss** (or **Comment**) only.
    var commentOnly = false
    /// Opens the card's thread; nil when the screen has no threads.
    var onDiscuss: (() -> Void)?
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
                        Label(SpecReviewPresentation.okLabel(kind), systemImage: "checkmark.circle.fill")
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
                case .viewed, nil:
                    let buttons: [SpecReviewCardButton] = commentOnly ? [.fix, .discuss] : SpecReviewCardActions.buttons(for: kind)
                    // A narrow drawer puts them on two rows.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.regular) { ForEach(buttons, id: \.self) { button($0) } }
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            ForEach(Array(stride(from: 0, to: buttons.count, by: 2)), id: \.self) { start in
                                HStack(spacing: Spacing.regular) {
                                    ForEach(buttons[start..<min(start + 2, buttons.count)], id: \.self) { button($0) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .controlSize(.small)
        .disabled(model.isAnswering)
    }

    /// One of the card's buttons. The loop's own picks (Reviewer is right,
    /// Author is right, Reopen) live on the loop's cards, not here.
    @ViewBuilder
    private func button(_ button: SpecReviewCardButton) -> some View {
        switch button {
        case .fix: fixButton
        case .skip:
            Button("Skip") { Task { await model.mark(key, .ok) } }
                .buttonStyle(.kitSecondary)
                .help("Keep the document as it is")
        case .checked:
            Button("Checked") { Task { await model.mark(key, .ok) } }
                .buttonStyle(.kitSecondary)
                .help("You checked it: nothing goes to the author")
        case .notUseful: notUsefulButton
        case .discuss:
            if let onDiscuss {
                Button("Discuss", action: onDiscuss)
                    .buttonStyle(.kitSecondary)
                    .help("Ask the assistant about this finding")
            } else {
                commentButton
            }
        case .reviewerRight, .authorRight, .reopen:
            EmptyView()
        }
    }

    private var fixButton: some View {
        Button("Fix") { Task { await model.mark(key, .comment) } }
            .buttonStyle(.kitSecondary)
            .help("The reviewer is right: send this finding to the author as it is")
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
