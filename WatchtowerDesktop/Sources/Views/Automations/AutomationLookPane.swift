import DesignKit
import SwiftUI
import WatchtowerCore

/// The automation editor's Look step (Inbox builder A, spec "The Look
/// step"): the card a dry run made, drawn as the Inbox draws it with every
/// button disabled, and each other state of the spec's table. A view over
/// a plain value; `AutomationLookPreviewModel` feeds it (plan Tasks 11–12).
struct AutomationLookPane: View {
    let content: AutomationLookPaneContent
    /// The owner's **Dry run**; nil hides it.
    var onDryRun: (() -> Void)?
    /// **Stop** of a running dry run.
    var onStop: () -> Void = {}
    /// The card picker's choice.
    var onSelect: (Int) -> Void = { _ in }
    var now = Date()

    /// The dimming of a preview under a running or stale dry run.
    static let dimmedOpacity = 0.45
    static let emptyLine = "Dry-run the recipe to see its card on your data."

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            switch content {
            case .noInboxOutput:
                placeholder(icon: "tray.slash", "This automation doesn't make an Inbox card.",
                            detail: "Ask the chat to put its result in the Inbox.", showsDryRun: false)
            case .empty:
                placeholder(icon: "rectangle.on.rectangle", Self.emptyLine, detail: nil, showsDryRun: true)
            case let .running(previous):
                runningLine
                if let previous {
                    cards(previous).opacity(Self.dimmedOpacity)
                } else {
                    placeholder(icon: "rectangle.on.rectangle", Self.emptyLine, detail: nil, showsDryRun: false)
                        .opacity(Self.dimmedOpacity)
                }
            case let .failed(message, steps):
                failure(message: message, steps: steps)
            case let .noCard(tokens):
                placeholder(icon: "tray", "This dry run made no card — it found nothing to show.",
                            detail: AutomationLookPaneContent.runLine(tokens: tokens, at: nil, now: now),
                            showsDryRun: true)
            case let .preview(shown, tokens, at):
                Text(AutomationLookPaneContent.runLine(tokens: tokens, at: at, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                cards(shown)
            case let .stale(shown):
                notice("The recipe changed since this preview.", tone: .secondary, showsDryRun: true)
                cards(shown).opacity(Self.dimmedOpacity)
            case let .stopped(shown):
                notice("The dry run stopped at a Quick Connection; dry-run the saved recipe from its card to see the rest.",
                       tone: Tone.warning, showsDryRun: false)
                cards(shown)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - States

    private func placeholder(icon: String, _ title: String, detail: String?, showsDryRun: Bool) -> some View {
        VStack(spacing: Spacing.regular) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if showsDryRun { dryRunButton.padding(.top, Spacing.small) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.hero)
    }

    private var runningLine: some View {
        HStack(spacing: Spacing.regular) {
            ProgressView().controlSize(.small)
            Text("Dry run — reading your data…").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Stop", action: onStop)
                .buttonStyle(.kitSecondary)
                .controlSize(.small)
        }
    }

    private func notice(_ text: String, tone: Color, showsDryRun: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(text)
                .font(.caption)
                .foregroundStyle(tone)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if showsDryRun { dryRunButton }
        }
    }

    private func failure(message: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            // No close: the error stays until the next dry run of this text.
            WriteErrorBanner(message: "The dry run failed: \(message)", onClose: nil)
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("Last steps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Text(step).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            dryRunButton
        }
    }

    @ViewBuilder private var dryRunButton: some View {
        if let onDryRun {
            Button("Dry run", action: onDryRun)
                .buttonStyle(.kitSecondary)
                .controlSize(.small)
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func cards(_ shown: AutomationLookPaneContent.Shown) -> some View {
        if shown.cards.indices.contains(shown.selected) {
            if shown.cards.count > 1 { picker(shown.cards, selected: shown.selected) }
            AutomationLookCard(card: shown.cards[shown.selected])
        }
    }

    private func picker(_ cards: [AutomationLookPaneContent.Card], selected: Int) -> some View {
        Menu {
            ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                Button(AutomationLookPaneContent.pickerTitle(card, index: index, count: cards.count)) { onSelect(index) }
            }
        } label: {
            MenuLabel(text: AutomationLookPaneContent.pickerTitle(cards[selected], index: selected, count: cards.count),
                      systemImage: "rectangle.stack", color: .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// One dry-run card as the Inbox draws it, in `.preview` mode: title and
/// priority above its blocks or its body.
struct AutomationLookCard: View {
    let card: AutomationLookPaneContent.Card

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(card.title.isEmpty ? "Automation output" : card.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if card.priority == "high" {
                    Chip(text: "High", color: Tone.priority("high"))
                }
            }
            ArtifactCardBody(blocksJSON: card.blocksJSON, actionsJSON: card.actionsJSON, text: card.body,
                             mode: .preview)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.medium)
        .card()
    }
}

/// The footer line above Save when the change adds an `llm()` step (spec
/// "The AI-step warning"), on every step of the editor.
struct AutomationLLMStepWarning: View {
    /// The dry run of this text, when one exists.
    let dryRunTokens: Int?

    static let text = "This change adds an AI step: every run will use the model."

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Image(systemName: "exclamationmark.triangle")
            if let dryRunTokens {
                Text(Self.text + " This dry run used "
                    + AutomationCardPresentation.tokensText(Int64(dryRunTokens), estimated: false) + ".")
            } else {
                Text(Self.text)
            }
        }
        .font(.callout)
        .foregroundStyle(Tone.warning)
        .fixedSize(horizontal: false, vertical: true)
    }
}
