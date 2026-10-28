import SwiftUI
import WatchtowerCore

/// Spec review, step 1 (spec §7): the ask's own header (its summary, focus
/// points, what changed on a re-round, its questions to answer), then does
/// the document carry the owner's idea — the idea next to the document's
/// goal with the verdict — a spec's Decisions list (a plan has none), the counts, the
/// reviewer's summary, its notes (trimmed inputs, dropped findings, code
/// not read) and, on a re-round, which of the owner's earlier comments are
/// resolved.
struct SpecReviewMeaningView<AskContext: View>: View {
    let model: SpecReviewModel
    let result: SpecReviewResult
    let askContext: () -> AskContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                askContext()
                if let idea = result.idea { ideaCard(idea) }
                if model.showsDecisions { decisionsList }
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    SectionHeader(title: "Reviewer's summary", systemImage: "text.magnifyingglass")
                    Text(SpecReviewPresentation.countsLine(result)).font(.callout.weight(.medium).monospacedDigit())
                    if !result.summary.isEmpty {
                        Text(result.summary).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                let notes = SpecReviewPresentation.notes(row: model.row, result: result)
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        SectionHeader(title: "Notes", systemImage: "info.circle")
                        ForEach(notes, id: \.self) {
                            Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !result.resolved.isEmpty { resolvedList }
                SpecReviewNextStepButton(model: model)
            }
            .frame(maxWidth: ReadableColumn.maxLineWidth, alignment: .leading)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity)
        }
    }

    private func ideaCard(_ idea: SpecReviewResult.Idea) -> some View {
        let verdict = SpecReviewPresentation.verdictBadge(idea.verdict)
        return VStack(alignment: .leading, spacing: Spacing.medium) {
            if !idea.ownerQuote.isEmpty {
                SpecReviewQuote(label: SpecReviewPresentation.ideaLabel(idea), quote: idea.ownerQuote)
            }
            if !idea.goalQuote.isEmpty {
                SpecReviewQuote(label: "The document's goal", quote: idea.goalQuote)
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Chip(text: verdict.title, color: verdict.tint.color)
                if !idea.note.isEmpty {
                    Text(idea.note).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// The document's own `## Decisions` lines, as the reviewer checked them.
    private var decisionsList: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            let items = model.decisions
            SectionHeader(title: "Decisions", systemImage: "list.bullet.rectangle", count: items?.count)
            if let items, !items.isEmpty {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                        Text("•").font(.callout).foregroundStyle(.secondary)
                        MarkdownView(text: item)
                    }
                }
            } else {
                Text(items == nil ? "The document has no Decisions section." : "The Decisions section is empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resolvedList: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            SectionHeader(title: "Your comments from the last round", systemImage: "arrow.uturn.backward",
                          count: result.resolved.count)
            ForEach(Array(result.resolved.enumerated()), id: \.offset) { _, item in
                let resolved = item.status == "resolved"
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Chip(text: resolved ? "Resolved" : "Open", color: resolved ? Tone.success : Tone.warning)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        SpecReviewQuote(label: "Your comment", quote: item.commentQuote)
                        if !item.note.isEmpty {
                            Text(item.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
