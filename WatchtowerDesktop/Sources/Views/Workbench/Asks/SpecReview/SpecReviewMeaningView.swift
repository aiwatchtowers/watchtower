import SwiftUI
import WatchtowerCore

/// Spec review, step 1 (spec §7): does the document carry the owner's
/// idea — the idea next to the document's goal with the verdict — then the
/// counts, the reviewer's summary, its notes (trimmed inputs, dropped
/// findings, code not read) and, on a re-round, which of the owner's
/// earlier comments are resolved.
struct SpecReviewMeaningView: View {
    let model: SpecReviewModel
    let result: SpecReviewResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                if let idea = result.idea { ideaCard(idea) }
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
                            Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !result.resolved.isEmpty { resolvedList }
                SpecReviewNextStepButton(model: model)
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
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

    private var resolvedList: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            SectionHeader(title: "Your comments from the last round", systemImage: "arrow.uturn.backward",
                          count: result.resolved.count)
            ForEach(Array(result.resolved.enumerated()), id: \.offset) { _, item in
                let resolved = item.status == "resolved"
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Chip(text: resolved ? "Resolved" : "Open", color: resolved ? Tone.success : Tone.warning)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text("“\(item.commentQuote)”").font(.callout).italic().fixedSize(horizontal: false, vertical: true)
                        if !item.note.isEmpty {
                            Text(item.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// One readable column, centred in a wide drawer (style guide).
    private static let columnWidth: CGFloat = 760
}
