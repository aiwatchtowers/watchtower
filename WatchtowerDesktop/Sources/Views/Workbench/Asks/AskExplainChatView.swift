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
                    if let failure = error ?? Self.startFailure(engine) {
                        AskExplainErrorRow(message: failure, onRetry: onRetry)
                    }
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

    /// The hidden first turn failed before its reply row existed (the CLI
    /// exited early): no row carries it or offers Retry, so the chat does.
    /// An owner send that failed the same way put its text back into the
    /// draft: then only the composer's own error status shows, and Retry
    /// (which would send the explanation prompt instead) does not. A failure
    /// after a reply row keeps the feed's own card.
    static func startFailure(_ engine: EmbeddedChatEngine) -> String? {
        guard engine.messages.isEmpty, !engine.isBusy,
              engine.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return engine.bannerError
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
/// before that the strip over a spinner or the open's failure. It makes the
/// engine again when the center let an idle one go (`.task`, never the body).
struct AskExplainPane: View {
    let asks: OwnerAsksViewModel
    let ask: OwnerAsk
    let onBack: () -> Void

    var body: some View {
        let engine = asks.explainEngine(for: ask)
        Group {
            switch Self.shown(hasEngine: engine != nil, error: asks.explainErrors[ask.id]) {
            case .chat:
                if let engine { chat(engine) }
            case let .failure(error):
                VStack(alignment: .leading, spacing: 0) {
                    AskExplainStrip(title: ask.title, onBack: onBack)
                    AskExplainErrorRow(message: error, onRetry: retry)
                        .padding(.vertical, Spacing.regular)
                    Spacer(minLength: 0)
                }
            case .finding:
                VStack(spacing: 0) {
                    AskExplainStrip(title: ask.title, onBack: onBack)
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: ask.id) { asks.ensureExplainEngine(ask) }
    }

    /// What the pane shows: the chat once the engine is there (its own
    /// feed and composer indicate a turn), else the open's failure, else a
    /// spinner while the conversation is found or created.
    enum Shown: Equatable { case chat, failure(String), finding }

    static func shown(hasEngine: Bool, error: String?) -> Shown {
        if hasEngine { return .chat }
        return error.map(Shown.failure) ?? .finding
    }

    @ViewBuilder
    private func chat(_ engine: EmbeddedChatEngine) -> some View {
        let view = AskExplainChatView(ask: ask, engine: engine, error: asks.explainErrors[ask.id], onRetry: retry, onBack: onBack)
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
