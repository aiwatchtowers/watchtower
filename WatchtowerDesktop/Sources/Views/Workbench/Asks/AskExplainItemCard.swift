import ChatUI
import SwiftUI
import WatchtowerCore

/// The item a "Not clear?" chat is about, pinned under the strip (spec
/// 2026-11-27 D5, D6): a question in bold with its option labels one per
/// line (Recommended marked as the ask's question card marks it, no
/// descriptions), or a step's number, text and hint. Past
/// `AskExplainCardLayout.clampHeight` it is cut there with a fade and
/// **Show more**; expanded it grows to `expandedMaxHeight` and scrolls inside
/// itself past it, with **Show less**. The pane gives it the item as its id,
/// so expansion resets when another item's chat shows.
struct AskExplainItemCard: View {
    let card: AskExplainCard
    @State private var expanded = false
    /// The content's own height, read after layout.
    @State private var contentHeight: CGFloat = 0

    init(card: AskExplainCard) {
        self.card = card
    }

    var body: some View {
        let mode = AskExplainCardLayout.mode(contentHeight: contentHeight, expanded: expanded)
        VStack(alignment: .leading, spacing: Spacing.small) {
            sized(mode)
            if AskExplainCardLayout.showsToggle(mode) {
                toggle
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private func sized(_ mode: AskExplainCardLayout.Mode) -> some View {
        switch mode {
        case .whole, .expanded:
            measured
        case .clamped:
            measured
                .frame(maxHeight: AskExplainCardLayout.clampHeight, alignment: .top)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
        case .expandedScrolling:
            ScrollView { measured }
                .frame(height: AskExplainCardLayout.expandedMaxHeight)
        }
    }

    /// The content at its full height, which it reports to `contentHeight`.
    private var measured: some View {
        AskExplainItemCardContent(card: card)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: AskExplainCardHeightKey.self, value: geometry.size.height)
            })
            .onPreferenceChange(AskExplainCardHeightKey.self) { contentHeight = $0 }
    }

    private var toggle: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                withAnimation(Motion.toggle) { expanded.toggle() }
            } label: {
                Label(expanded ? AskExplainCopy.showLess : AskExplainCopy.showMore,
                      systemImage: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
            .buttonStyle(KitQuietButtonStyle(label: .secondary))
        }
    }
}

/// The card's content at its natural height: the question with its option
/// labels, or the step with its hint.
struct AskExplainItemCardContent: View {
    let card: AskExplainCard

    var body: some View {
        switch card {
        case let .question(text, options):
            VStack(alignment: .leading, spacing: Spacing.small) {
                MarkdownView(text: text).fontWeight(.semibold)
                if !options.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            optionRow(option)
                        }
                    }
                }
            }
        case let .step(number, text, hint):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    MarkdownView(text: text).fontWeight(.semibold)
                    if !hint.isEmpty {
                        MarkdownView(text: hint).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func optionRow(_ option: AskExplainCard.Option) -> some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "circle").font(.caption2).foregroundStyle(.tertiary)
            Text(MarkdownView.inlineLabel(option.label)).font(.caption).lineLimit(1).truncationMode(.tail)
            if option.recommended {
                // The mark the ask's own question card draws.
                DesignKitChatStyle(look: .ask).recommendedMark(AskExplainCopy.recommended)
            }
        }
    }
}

/// The card content's height, read by `AskExplainItemCard`.
private struct AskExplainCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
