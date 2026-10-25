import SwiftUI
import WatchtowerCore

/// Spec review, step 2 (spec §7): the document's chapters on the left —
/// heading, a badge per kind of finding, ✓ once Viewed — and the current
/// chapter on the right: its text folded, the finding cards, the
/// chapter's checklist, then **Viewed**. A chapter without findings is
/// marked Viewed from its row in one click.
struct SpecReviewChaptersView: View {
    let model: SpecReviewModel

    var body: some View {
        let chapters = model.chapters
        HSplitView {
            list(chapters)
                .frame(minWidth: PaneWidth.sideListMin, idealWidth: PaneWidth.sideListIdeal, maxWidth: PaneWidth.sideListMax)
            detail(chapters.first { $0.key == model.chapterKey } ?? chapters.first)
                .frame(minWidth: PaneWidth.detailMin, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ chapters: [SpecReviewChapterVM]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if chapters.isEmpty {
                    Text("No chapters").foregroundStyle(.secondary).padding(Spacing.regular)
                }
                ForEach(chapters) { row($0) }
            }
            .padding(Spacing.compact)
        }
    }

    private func row(_ chapter: SpecReviewChapterVM) -> some View {
        let current = chapter.key == model.chapterKey
        let empty = chapter.findings.isEmpty && chapter.checks.isEmpty
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Image(systemName: chapter.viewed ? "checkmark.circle.fill" : empty ? "checkmark" : "circle")
                .foregroundStyle(chapter.viewed ? Tone.success : Color.secondary)
                .accessibilityLabel(chapter.viewed ? "Viewed" : empty ? "No findings" : "Not viewed")
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(chapter.heading.isEmpty ? "Untitled" : chapter.heading)
                    .font(.callout)
                    .fontWeight(current ? .semibold : .regular)
                    .lineLimit(2)
                let badges = SpecReviewPresentation.chapterBadges(chapter)
                if !badges.isEmpty {
                    HStack(spacing: Spacing.small) {
                        ForEach(badges, id: \.badge) { Chip(text: "\($0.count) \($0.badge.title)", color: $0.badge.tint.color) }
                    }
                }
            }
            Spacer(minLength: Spacing.small)
            if empty, !chapter.viewed {
                Button("Viewed") { Task { await model.mark(chapter.key, .viewed) } }
                    .buttonStyle(.kitQuiet)
                    .controlSize(.small)
                    .help("Nothing found here: mark it Viewed")
            }
        }
        .kitRow(isSelected: current)
        .contentShape(Rectangle())
        .onTapGesture { model.chapterKey = chapter.key }
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func detail(_ chapter: SpecReviewChapterVM?) -> some View {
        if let chapter {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    Text(chapter.heading.isEmpty ? "Untitled" : chapter.heading).font(.headline)
                    if !chapter.excerpt.isEmpty {
                        SpecReviewExcerpt(text: String(chapter.excerpt))
                    }
                    if chapter.findings.isEmpty {
                        Text("The reviewer found nothing to raise in this chapter.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(chapter.findings, id: \.key) { SpecReviewFindingCard(model: model, finding: $0) }
                    if !chapter.checks.isEmpty {
                        SectionHeader(title: "Checklist", systemImage: "checklist", count: chapter.checks.count)
                            .padding(.top, Spacing.small)
                        ForEach(chapter.checks, id: \.key) { checkRow($0) }
                    }
                    HStack {
                        viewedButton(chapter)
                        Spacer()
                    }
                    .padding(.top, Spacing.small)
                    SpecReviewNextStepButton(model: model)
                }
                .padding(Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(chapter.key)
        } else {
            Text("No chapters").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One lens question: the answer, the reviewer's note, and for a concern
    /// the marks a finding has.
    private func checkRow(_ check: SpecReviewResult.Check) -> some View {
        let badge = SpecReviewPresentation.checkBadge(answer: check.answer)
        return VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Chip(text: badge.title, color: badge.tint.color)
                Text(check.question).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !check.note.isEmpty {
                Text(check.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if check.answer == "concern" {
                SpecReviewMarkControls(model: model, key: check.key)
            }
        }
        .padding(Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
    }

    private func viewedButton(_ chapter: SpecReviewChapterVM) -> some View {
        Button {
            Task {
                if chapter.viewed { await model.unmark(chapter.key) } else { await model.mark(chapter.key, .viewed) }
            }
        } label: {
            Label("Viewed", systemImage: chapter.viewed ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.kitSecondary)
        .controlSize(.small)
        .help(chapter.viewed ? "Viewed — click to unmark" : "Mark this chapter Viewed")
    }
}

/// The chapter's text, folded until the owner opens it.
private struct SpecReviewExcerpt: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.regular)
                .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
        } label: {
            Text(expanded ? "Section text" : firstLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var firstLine: String {
        let line = text.split(separator: "\n").dropFirst().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { "Section text — \($0)" } ?? "Section text"
    }
}
