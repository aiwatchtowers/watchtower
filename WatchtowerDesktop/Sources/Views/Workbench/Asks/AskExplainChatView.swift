import AppKit
import SwiftUI
import WatchtowerCore

/// The "Not clear?" chat on the whole ask drawer under its header (spec
/// 2026-11-24 "The chat view"): a strip with **‹ Back to question** and the
/// ask's title on one line, the feed (compact, kept at its latest row), and
/// the composer. Esc in the composer goes back while it is empty and never
/// stops the turn: Stop stays on the composer's button.
struct AskExplainChatView: View {
    let ask: OwnerAsk
    let engine: EmbeddedChatEngine
    /// Why the last open could not read the chat again; its Retry opens it again.
    var error: String?
    var onRetry: (() -> Void)?
    let onBack: () -> Void

    init(
        ask: OwnerAsk,
        engine: EmbeddedChatEngine,
        error: String? = nil,
        onRetry: (() -> Void)? = nil,
        onBack: @escaping () -> Void
    ) {
        self.ask = ask
        self.engine = engine
        self.error = error
        self.onRetry = onRetry
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            AskExplainStrip(title: ask.title, onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    EmbeddedChatRows(engine: engine)
                        .padding(.horizontal, Spacing.medium)
                    AskExplainWaitingLine(engine: engine)
                    if let error { AskExplainErrorRow(message: error, onRetry: onRetry) }
                }
                .padding(.vertical, Spacing.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Follows the latest reply as it grows.
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: .infinity)
            EmbeddedChatComposer(engine: engine, placeholder: AskExplainCopy.placeholder, density: .compact,
                                 onEscape: Self.composerEscape(engine: engine, onBack: onBack), autoFocus: true)
        }
    }

    /// The composer's Esc (it reaches only a focused composer): back to the
    /// question while the field is empty; never `engine.stop()`.
    static func composerEscape(engine: EmbeddedChatEngine, onBack: @escaping () -> Void) -> () -> Void {
        { [weak engine] in
            guard let engine, AskExplainPresentation.escapeLeavesChat(composerFocused: true, draft: engine.draft) else { return }
            onBack()
        }
    }
}

/// The drawer's chat layer: the chat once its engine is in the center,
/// before that the strip with the wait or the open's failure. It makes the
/// engine again when the center let an idle one go (`.task`, never the body).
struct AskExplainPane: View {
    let asks: OwnerAsksViewModel
    let ask: OwnerAsk
    let onBack: () -> Void

    var body: some View {
        Group {
            if let engine = asks.explainEngine(for: ask) {
                chat(engine)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    AskExplainStrip(title: ask.title, onBack: onBack)
                    Group {
                        if let error = asks.explainErrors[ask.id] {
                            AskExplainErrorRow(message: error, onRetry: retry)
                        } else {
                            AskExplainStatusLine(text: AskExplainCopy.explaining)
                        }
                    }
                    .padding(.vertical, Spacing.regular)
                    Spacer(minLength: 0)
                }
            }
        }
        .task(id: ask.id) { asks.ensureExplainEngine(ask) }
    }

    @ViewBuilder
    private func chat(_ engine: EmbeddedChatEngine) -> some View {
        let view = AskExplainChatView(ask: ask, engine: engine, error: asks.explainErrors[ask.id], onRetry: retry, onBack: onBack)
            // The composer is made with the keyboard.
            .onAppear { asks.explainComposerTookFocus(ask.id) }
        if let chats = asks.chats {
            view.embeddedChatVisibility(engine.spec.key, in: chats)
        } else {
            view
        }
    }

    private func retry() {
        let (asks, ask) = (asks, ask)
        Task { await asks.openExplain(ask) }
    }
}

/// **‹ Back to question**, then the ask's title on one line.
private struct AskExplainStrip: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Button(action: onBack) {
                Label(AskExplainCopy.back, systemImage: "chevron.left").font(.caption)
            }
            .buttonStyle(.kitQuiet)
            .fixedSize()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Queued behind other chats, or the explanation on its way, until the
/// reply's first words: its own view, so only it re-reads a streaming turn.
private struct AskExplainWaitingLine: View {
    let engine: EmbeddedChatEngine

    var body: some View {
        let showsText = !(engine.liveTurn?.text.isEmpty ?? true) || engine.messages.contains { !$0.message.text.isEmpty }
        if let line = AskExplainPresentation.waitingLine(isQueued: engine.isQueued, isBusy: engine.isBusy, showsText: showsText) {
            AskExplainStatusLine(text: line)
        }
    }
}

private struct AskExplainStatusLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: text == AskExplainCopy.queued ? "hourglass" : "ellipsis")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.medium)
    }
}

/// "Couldn't explain: <reason>" with Retry.
private struct AskExplainErrorRow: View {
    let message: String
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Label("\(AskExplainCopy.errorPrefix) \(message)", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Tone.error)
                .fixedSize(horizontal: false, vertical: true)
            if let onRetry {
                Button(AskExplainCopy.retry, action: onRetry)
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Spacing.medium)
    }
}
