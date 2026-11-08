import SwiftUI
import WatchtowerCore

/// The summary that opens the Meaning step (spec 2026-11-08 §4): the
/// brief — what is built, for whom and why — then the theses grouped by
/// kind. Each thesis is one line; opening it shows the passage it quotes,
/// **Read the spec** and **Discuss** (a thread keyed by the thesis key).
/// Theses carry no marks and never go to the author.
struct SpecReviewSummaryView: View {
    let brief: String
    let theses: [SpecReviewResult.Thesis]
    /// Nil: no threads on this screen, no **Discuss**.
    let onDiscuss: ((SpecReviewResult.Thesis) -> Void)?
    /// Nil: no **Read the spec** link.
    var onReadSpec: ((SpecReviewResult.Thesis) -> Void)?
    @State private var expanded: Set<String>

    init(
        brief: String,
        theses: [SpecReviewResult.Thesis],
        onDiscuss: ((SpecReviewResult.Thesis) -> Void)?,
        onReadSpec: ((SpecReviewResult.Thesis) -> Void)? = nil,
        expanded: Set<String> = []
    ) {
        self.brief = brief
        self.theses = theses
        self.onDiscuss = onDiscuss
        self.onReadSpec = onReadSpec
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            SectionHeader(title: "In short", systemImage: "text.alignleft")
            if !brief.isEmpty {
                Text(brief).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ForEach(SpecReviewPresentation.thesisGroups(theses), id: \.title) { group in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Label(group.title, systemImage: group.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, Spacing.tight)
                    ForEach(group.theses, id: \.key) { thesis in
                        SpecReviewThesisRow(
                            thesis: thesis,
                            isExpanded: Binding(
                                get: { expanded.contains(thesis.key) },
                                set: { if $0 { expanded.insert(thesis.key) } else { expanded.remove(thesis.key) } }
                            ),
                            onDiscuss: onDiscuss.map { discuss in { discuss(thesis) } },
                            onReadSpec: onReadSpec.map { read in { read(thesis) } }
                        )
                    }
                }
            }
        }
    }
}

/// One thesis: its line with a disclosure chevron; open, the quoted
/// passage, **Read the spec** and **Discuss**, and its thread.
struct SpecReviewThesisRow: View {
    let thesis: SpecReviewResult.Thesis
    @Binding var isExpanded: Bool
    let onDiscuss: (() -> Void)?
    let onReadSpec: (() -> Void)?
    @State private var thread = SpecReviewThreadVisibility.auto

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Button {
                withAnimation(Motion.toggle) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: IconSize.chevron)
                    Text(thesis.text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    if let anchor = thesis.anchor, !anchor.quote.isEmpty {
                        SpecReviewQuote(label: anchor.heading.isEmpty ? "The document says" : "The document says · \(anchor.heading)",
                                        quote: anchor.quote)
                    }
                    HStack(spacing: Spacing.regular) {
                        if let onReadSpec {
                            Button("Read the spec", action: onReadSpec)
                                .buttonStyle(.kitQuiet)
                                .help("Open the document at this passage")
                        }
                        Spacer()
                        if let onDiscuss {
                            Button("Discuss") {
                                thread = .shown
                                onDiscuss()
                            }
                            .buttonStyle(.kitSecondary)
                            .help("Ask the assistant about this thesis")
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, IconSize.chevron + Spacing.compact)
            }
            SpecReviewCardThreadSection(key: thesis.key, visibility: $thread, placeholder: "Ask about this thesis")
                .padding(.leading, IconSize.chevron + Spacing.compact)
        }
        .padding(.vertical, Spacing.small)
        .padding(.horizontal, Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isExpanded ? Fill.rest : Color.clear, in: RoundedRectangle(cornerRadius: Radius.row))
    }
}
