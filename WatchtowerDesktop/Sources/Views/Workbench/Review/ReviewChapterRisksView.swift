import SwiftUI
import WatchtowerCore

/// What the AI overview flags in the current chapter (#961): one row per
/// risk of the chapter's files — level, why, the file — with Comment… to turn
/// it into a design comment and Ask agent to put it to the session's agent.
/// Without an overview the section offers to run one.
struct ReviewChapterRisksView: View {
    let model: ReviewChangesModel
    let onComment: (ReviewChangesPaneView.ComposeRequest) -> Void
    let onAsk: (ReviewOverview.Risk) -> Void
    /// Ask agent shows only where the caller wires it.
    var canAsk = false

    var body: some View {
        if let key = model.currentChapterKey {
            let risks = model.chapterRisks(key)
            Divider()
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text("What to look at in this chapter").font(.caption.weight(.semibold))
                if case .ready = model.overview {
                    if risks.isEmpty {
                        Text("The AI overview flags nothing in this chapter.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(risks.enumerated()), id: \.offset) { row($0.element) }
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
            Text(Self.label(risk.level))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Self.color(risk.level))
                .padding(.horizontal, Spacing.small)
                .background(Self.color(risk.level).opacity(0.15), in: Capsule())
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

    private static func label(_ level: ReviewOverview.Risk.Level) -> String {
        switch level {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    private static func color(_ level: ReviewOverview.Risk.Level) -> Color {
        switch level {
        case .high: .red
        case .medium: .orange
        case .low: .secondary
        }
    }
}
