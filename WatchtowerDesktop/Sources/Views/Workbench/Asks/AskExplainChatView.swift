import AppKit
import SwiftUI
import WatchtowerCore

/// The "Not clear?" chat about one item of an ask, under the pane's strip
/// and item card (spec 2026-11-27 "The chat view"): the feed (compact, kept
/// at its latest row) and the composer with the item's placeholder. Esc in
/// the composer goes back while it is empty and never stops the turn: Stop
/// stays on the composer's button.
struct AskExplainChatView: View {
    let ask: OwnerAsk
    let item: AskExplainItem
    let engine: EmbeddedChatEngine
    /// Why the last open could not read the chat again; its Retry opens it again.
    var error: String?
    var onRetry: (() -> Void)?
    let onBack: () -> Void

    init(
        ask: OwnerAsk,
        item: AskExplainItem,
        engine: EmbeddedChatEngine,
        error: String? = nil,
        onRetry: (() -> Void)? = nil,
        onBack: @escaping () -> Void
    ) {
        self.ask = ask
        self.item = item
        self.engine = engine
        self.error = error
        self.onRetry = onRetry
        self.onBack = onBack
    }

    /// The strip's Back label and its item label: "Back to question" and
    /// "Question 2", or "Back to check" and "Step 2".
    static func stripLabels(_ item: AskExplainItem) -> (back: String, item: String) {
        (AskExplainCopy.back(for: item), AskExplainCopy.itemLabel(item))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    EmbeddedChatRows(engine: engine)
                        .padding(.horizontal, Spacing.medium)
                    if let line = Self.failureLine(openError: error, engine: engine) {
                        AskExplainErrorRow(text: line, onRetry: onRetry)
                    }
                }
                .padding(.vertical, Spacing.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Follows the latest reply as it grows.
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: .infinity)
            composer
        }
    }

    /// The composer: compact, Esc back while empty, and no second copy of a
    /// failure the row above already shows (`composerHidesError`).
    var composer: EmbeddedChatComposer {
        EmbeddedChatComposer(engine: engine, placeholder: AskExplainCopy.placeholder(for: item), density: .compact,
                             onEscape: Self.composerEscape(engine: engine, onBack: onBack), autoFocus: true,
                             hidesError: Self.composerHidesError(engine))
    }

    /// The hidden first turn could not start (the CLI exited early): no row
    /// carries it or offers Retry, so the chat does — whatever the draft
    /// holds. An owner send that failed the same way is not a hidden turn:
    /// only the composer's own error status and its restored text show,
    /// never a Retry that would send the explanation prompt instead. A
    /// failure after a reply row keeps the feed's own card.
    static func startFailure(_ engine: EmbeddedChatEngine) -> String? {
        guard engine.hiddenTurnNotStarted, engine.messages.isEmpty, !engine.isBusy else { return nil }
        return engine.bannerError
    }

    /// A first turn that never started shows its failure once: in the
    /// row with Retry above, not again on the composer's status line. Any
    /// other failure keeps the composer's own status.
    static func composerHidesError(_ engine: EmbeddedChatEngine) -> Bool {
        startFailure(engine) != nil
    }

    /// The failure row's text: a failed open says "Couldn't explain: <reason>";
    /// a hidden first turn that never started shows the engine's own banner,
    /// which already says what failed ("Couldn't send: …").
    static func failureLine(openError: String?, engine: EmbeddedChatEngine) -> String? {
        if let openError { return AskExplainErrorRow.openFailure(openError) }
        return startFailure(engine)
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
/// before that the strip and the item's card over a spinner or the open's
/// failure (spec 2026-11-27 D13). It makes the engine again when the center
/// let an idle one go (`.task`, never the body).
struct AskExplainPane: View {
    let asks: OwnerAsksViewModel
    let ask: OwnerAsk
    let item: AskExplainItem
    let onBack: () -> Void

    private var subject: AskExplainSubject { AskExplainSubject(askID: ask.id, item: item) }

    var body: some View {
        let engine = asks.explainEngine(for: ask, item: item)
        let shown = Self.shown(hasEngine: engine != nil, error: asks.explainErrors[subject])
        let card = Self.showsCard(shown) ? AskExplainCard.make(ask: ask, item: item) : nil
        Self.layout(shown, subject: subject, card: card, onRetry: retryIfItCanHelp, onBack: onBack) {
            if let engine { chat(engine) }
        }
        .task(id: subject) { asks.ensureExplainEngine(ask, item: item) }
    }

    /// What the pane shows: the chat once the engine is there (its own
    /// feed and composer indicate a turn), else the open's failure, else a
    /// spinner while the conversation is found or created.
    enum Shown: Equatable { case chat, failure(String), finding }

    static func shown(hasEngine: Bool, error: String?) -> Shown {
        if hasEngine { return .chat }
        return error.map(Shown.failure) ?? .finding
    }

    /// The item's card shows under the strip in every state (spec D13): it
    /// needs no read, so the owner sees what the chat is about at once.
    static func showsCard(_ shown: Shown) -> Bool {
        switch shown {
        case .chat, .failure, .finding: true
        }
    }

    /// One state of the pane: the strip and the item's card, drawn once
    /// above whatever the state shows under them — the chat, the open's
    /// failure or a spinner — so the card keeps its expansion as the state
    /// moves on.
    static func layout(
        _ shown: Shown,
        subject: AskExplainSubject,
        card: AskExplainCard?,
        onRetry: (() -> Void)?,
        onBack: @escaping () -> Void,
        @ViewBuilder chat: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AskExplainItemHeader(subject: subject, card: card, onBack: onBack)
            switch shown {
            case .chat:
                chat()
            case let .failure(error):
                AskExplainErrorRow(text: AskExplainErrorRow.openFailure(error), onRetry: onRetry)
                    .padding(.vertical, Spacing.large)
                Spacer(minLength: 0)
            case .finding:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The chat over `engine`, with the open's error and its Retry when one
    /// can help.
    func chatView(_ engine: EmbeddedChatEngine) -> AskExplainChatView {
        AskExplainChatView(ask: ask, item: item, engine: engine, error: asks.explainErrors[subject],
                           onRetry: retryIfItCanHelp, onBack: onBack)
    }

    @ViewBuilder
    private func chat(_ engine: EmbeddedChatEngine) -> some View {
        let view = chatView(engine)
        if let chats = asks.chats {
            view.embeddedChatVisibility(engine.spec.key, in: chats)
        } else {
            view
        }
    }

    /// Retry, unless the open failed for good (the workbench is gone): the
    /// line then stays as the final state, Back leaves it.
    var retryIfItCanHelp: (() -> Void)? {
        asks.explainOffersRetry(subject) ? retry : nil
    }

    private func retry() {
        let (asks, ask, item) = (asks, ask, item)
        Task { await asks.openExplain(ask, item: item) }
    }
}

/// The top of every pane state: the strip, then the item's card, pinned
/// (it never scrolls with the feed). The card takes its subject as its id,
/// so its expansion resets when another item's chat shows, of this ask or
/// another (spec D6).
struct AskExplainItemHeader: View {
    let subject: AskExplainSubject
    let card: AskExplainCard?
    let onBack: () -> Void
    @Environment(\.askExplainCardStartsExpanded) private var startsExpanded

    var body: some View {
        VStack(spacing: 0) {
            AskExplainStrip(item: subject.item, onBack: onBack)
            if let card {
                AskExplainItemCard(card: card, startsExpanded: startsExpanded)
                    .id(subject)
                    .padding(.horizontal, Spacing.medium)
            }
        }
    }
}

/// **‹ Back to question** (or **‹ Back to check**), and on the right which
/// item the chat is about: "Question 2", "Step 3" (spec D7). The drawer
/// header carries the ask's title, the card the item.
private struct AskExplainStrip: View {
    let item: AskExplainItem
    let onBack: () -> Void

    var body: some View {
        let labels = AskExplainChatView.stripLabels(item)
        HStack(spacing: Spacing.compact) {
            Button(action: onBack) {
                Label(labels.back, systemImage: "chevron.left").font(.caption)
            }
            .buttonStyle(.kitQuiet)
            .fixedSize()
            Spacer(minLength: Spacing.compact)
            Text(labels.item)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.bottom, Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A failure line with Retry.
struct AskExplainErrorRow: View {
    let text: String
    let onRetry: (() -> Void)?

    /// "Couldn't explain: <reason>", for an open that failed.
    static func openFailure(_ reason: String) -> String {
        "\(AskExplainCopy.errorPrefix) \(reason)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Label(text, systemImage: "exclamationmark.triangle")
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

extension EnvironmentValues {
    /// Draws the item's card expanded, as after **Show more**: set by the
    /// built design shot `expanded` only, never by the app.
    @Entry var askExplainCardStartsExpanded = false
}
