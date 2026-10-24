import SwiftUI
import WatchtowerCore

/// What the AI overview flags in the current chapter (#961): one row per
/// risk of the chapter's files — level, why, the file — with Comment… to turn
/// it into a design comment and Ask agent to put it to the session's agent.
/// An overview that failed to refresh or is of an earlier version still shows
/// its risks, marked out of date. Without an overview the section offers to
/// run one. A long list scrolls.
struct ReviewChapterRisksView: View {
    let model: ReviewChangesModel
    let onComment: (ReviewChangesPaneView.ComposeRequest) -> Void
    let onAsk: (ReviewOverview.Risk) -> Void
    /// Ask agent shows only where the caller wires it.
    var canAsk = false

    /// The list's height before it scrolls, so the diff keeps the pane.
    private static let maxListHeight: CGFloat = 160

    var body: some View {
        if let key = model.currentChapterKey {
            Divider()
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text("What to look at in this chapter").font(.caption.weight(.semibold))
                if let list = model.chapterRiskList(key) {
                    if list.outOfDate {
                        Text("Out of date — from an earlier AI overview of this branch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if list.risks.isEmpty {
                        Text("The AI overview flags nothing in this chapter.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: Spacing.small) {
                                ForEach(Array(list.risks.enumerated()), id: \.offset) { row($0.element) }
                            }
                        }
                        .frame(maxHeight: Self.maxListHeight)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    unavailable
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.small)
        }
    }

    private var unavailable: some View {
        HStack {
            switch model.overview {
            case .loading:
                ProgressView().controlSize(.small)
                Text("The AI overview is being made…").font(.caption).foregroundStyle(.secondary)
            default:
                Text("No AI overview yet, so no risks to show.").font(.caption).foregroundStyle(.secondary)
                Button("Run AI overview") { model.makeOverview() }
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
            }
        }
    }

    private func row(_ risk: ReviewOverview.Risk) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            ReviewRiskBadge(level: risk.level, showsLow: true)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(risk.why).font(.callout)
                Button((risk.path as NSString).lastPathComponent) { Task { await model.select(risk.path) } }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(risk.path)
            }
            Spacer(minLength: Spacing.small)
            Button("Comment…") {
                onComment(.init(title: "Design comment", prefill: "\(risk.path) — \(risk.why)") { body in
                    try await model.addDesignComment(body: body)
                })
            }
            .buttonStyle(.borderless)
            .disabled(model.round?.status != "open")
            if canAsk {
                Button("Ask agent") { onAsk(risk) }
                    .buttonStyle(.borderless)
                    .help("Quote this risk in the agent's chat")
            }
        }
    }
}
