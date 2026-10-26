import SwiftUI
import WatchtowerCore

/// Spec review, step 3 (spec §7): every finding grouped with the owner's
/// mark, an unmarked one flagged (a click opens its chapter); **From the
/// previous run** for comments whose finding the re-run did not find again;
/// the note; then **Send round to the author** (verdict `changes`, needs a
/// comment) and **Approve** (asks once while findings are unmarked).
struct SpecReviewWrapUpView: View {
    let model: SpecReviewModel
    let result: SpecReviewResult
    @State private var confirmingApprove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                ForEach(SpecReviewPresentation.wrapUpGroups(result)) { group in
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        SectionHeader(title: group.title, systemImage: icon(group.title), count: group.items.count)
                        ForEach(group.items) { itemRow($0) }
                    }
                }
                if SpecReviewPresentation.wrapUpGroups(result).isEmpty {
                    Text("The reviewer raised no findings.").font(.callout).foregroundStyle(.secondary)
                }
                if !model.orphans.isEmpty { orphanList }
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
    }

    private func itemRow(_ item: SpecReviewPresentation.WrapUpItem) -> some View {
        let mark = model.marks[item.key]
        return Button {
            let keys = Set(model.chapters.map(\.key))
            model.chapterKey = keys.contains(item.chapter) ? item.chapter : SpecReviewChapterVM.otherKey
            model.phase = .chapters
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                markGlyph(mark?.state)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(item.text).font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    if mark?.state == .comment, let body = mark?.body, !body.isEmpty {
                        Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Spacing.regular)
                if mark == nil {
                    Text("Not marked").font(.caption2.weight(.medium)).foregroundStyle(Tone.warning)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .kitRow(isSelected: false)
        .help("Open its chapter")
    }

    @ViewBuilder
    private func markGlyph(_ state: SpecReviewMarkState?) -> some View {
        switch state {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success).accessibilityLabel("Fine as is")
        case .comment:
            Image(systemName: "text.bubble.fill").foregroundStyle(Color.accentColor).accessibilityLabel("Comment")
        case .viewed, nil:
            Image(systemName: "exclamationmark.circle").foregroundStyle(Tone.warning).accessibilityLabel("Not marked")
        }
    }

    private var orphanList: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            SectionHeader(title: "From the previous run", systemImage: "clock.arrow.circlepath", count: model.orphans.count)
            Text("The re-run did not find these again; your comments still go to the author.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.orphans, id: \.key) { mark in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    markGlyph(mark.state)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        if !mark.about.isEmpty {
                            Text(mark.about).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(mark.body)
                            .font(mark.about.isEmpty ? .callout : .caption)
                            .foregroundStyle(mark.about.isEmpty ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Spacing.regular)
                    Button("Remove") { Task { await model.unmark(mark.key) } }
                        .buttonStyle(.kitQuiet)
                        .controlSize(.small)
                }
                .padding(.horizontal, Spacing.regular)
                .padding(.vertical, Spacing.compact)
            }
        }
    }

    /// One prominent action: Send while there are comments, else Approve.
    /// Both stay off, with the reason, while the answer cannot go (an ask
    /// question not answered yet).
    private var actions: some View {
        let blocker = model.answerBlocker
        return VStack(alignment: .trailing, spacing: Spacing.small) {
            if let blocker {
                HStack(spacing: Spacing.compact) {
                    Text(blocker).font(.caption).foregroundStyle(Tone.warning)
                    if model.hasQuestions {
                        Button("Go to Meaning") { model.phase = .meaning }.buttonStyle(.kitQuiet)
                    }
                }
            }
            actionButtons.disabled(blocker != nil)
        }
        .controlSize(.small)
    }

    private var actionButtons: some View {
        HStack(spacing: Spacing.regular) {
            if model.isAnswering { ProgressView().controlSize(.small) }
            Spacer()
            if model.canSend {
                Button("Approve", action: pressApprove).buttonStyle(.kitSecondary)
                Button("Send round to the author", action: send).buttonStyle(.kitPrimary)
            } else {
                Button("Send round to the author", action: send)
                    .buttonStyle(.kitSecondary)
                    .disabled(true)
                    .help("Comment on a finding, or in the margin under Read the spec, first")
                Button("Approve", action: pressApprove).buttonStyle(.kitPrimary)
            }
        }
        .controlSize(.small)
        .disabled(model.isAnswering)
    }

    private func pressApprove() {
        if model.needsApproveConfirm { confirmingApprove = true } else { approve() }
    }

    // The answer's failures land in the ask's answer errors (the drawer's footer).
    private func approve() {
        Task { _ = await model.approve() }
    }

    private func send() {
        Task { _ = await model.send() }
    }

    private func icon(_ title: String) -> String {
        switch title {
        case "As agreed": "checkmark.seal"
        case "Differs": "arrow.left.arrow.right"
        case "Missing": "questionmark.square.dashed"
        case "Decided alone": "person.fill.questionmark"
        case "Blind spots": "eye.slash"
        case "Concerns": "exclamationmark.bubble"
        default: "circle.dashed"
        }
    }
}
