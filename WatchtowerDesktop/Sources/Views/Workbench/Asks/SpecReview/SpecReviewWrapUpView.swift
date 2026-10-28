import SwiftUI
import WatchtowerCore

/// Spec review, step 3 (spec §7): every finding grouped with the owner's
/// mark, an unmarked one flagged (a click opens its chapter); **From the
/// previous run** for comments whose finding the re-run did not find again;
/// the note. **Request changes** and **Approve** sit in the drawer's footer
/// (`SpecReviewVerdictButtons`).
struct SpecReviewWrapUpView: View {
    let model: SpecReviewModel
    let result: SpecReviewResult

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
            }
            .frame(maxWidth: ReadableColumn.maxLineWidth, alignment: .leading)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity)
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
                markGlyph(mark)
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
    private func markGlyph(_ mark: SpecReviewMark?) -> some View {
        switch mark?.state {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success).accessibilityLabel("Fine as is")
        case .comment where mark?.body.isEmpty ?? true:
            Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.secondary).accessibilityLabel("Fix")
        case .comment:
            Image(systemName: "text.bubble.fill").foregroundStyle(.secondary).accessibilityLabel("Comment")
        case .notUseful:
            Image(systemName: "hand.thumbsdown.fill").foregroundStyle(Color.secondary).accessibilityLabel("Not useful")
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
                    markGlyph(mark)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        if !mark.about.isEmpty {
                            Text(mark.about).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        if !mark.body.isEmpty {
                            Text(mark.body)
                                .font(mark.about.isEmpty ? .callout : .caption)
                                .foregroundStyle(mark.about.isEmpty ? .primary : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
