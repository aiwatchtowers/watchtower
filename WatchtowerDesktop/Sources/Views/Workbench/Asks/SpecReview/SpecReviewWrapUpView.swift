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
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
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
                    Text(mark.body).font(.callout).fixedSize(horizontal: false, vertical: true)
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
    private var actions: some View {
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
                    .help("Comment on at least one finding first")
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
        let note = model.note
        Task { _ = await model.approve(note: note) }
    }

    private func send() {
        let note = model.note
        Task { _ = await model.send(note: note) }
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

    private static let columnWidth: CGFloat = 760
}
