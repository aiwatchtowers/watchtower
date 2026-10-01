import Foundation
import WatchtowerCore

/// The "Setup Assistant" chat next to an account form (calendar, email) on
/// the shared embedded chat component. EPHEMERAL: a setup wizard chat is
/// throwaway, so its rows live in memory only (the sheet owns it) — only the
/// provider session carries turn-to-turn continuity within one presentation.
///
/// PRIVACY BOUNDARY (load-bearing): the assistant sees the form only through
/// a `Snapshot` and writes back only through a `Patch`; both types are
/// credential-free by construction (no password, no secret feed URL), so a
/// credential cannot reach a prompt or come back into the form.
@MainActor
@Observable
final class SetupAssistantChat<Snapshot, Patch> {
    let engine: EmbeddedChatEngine
    /// Invoked when a completed reply carries a settings block; the owning
    /// view writes the patch into its form fields.
    @ObservationIgnored var onApplySettings: ((Patch) -> Void)?
    /// The form as it is now — read for every turn (the composer, Retry), so
    /// the assistant always sees the current state. Set by the sheet.
    @ObservationIgnored var snapshotProvider: (() -> Snapshot)?
    /// The latest turn's failure; cleared by the next send.
    var errorMessage: String?

    @ObservationIgnored private var lastSnapshot: Snapshot?
    @ObservationIgnored private let greeting: String

    /// `parse` splits a reply into the text to show and the settings patch
    /// (nil when the reply carries none, or a malformed block).
    init(
        contextID: String,
        greeting: String,
        systemPrompt: String,
        filledPlaceholder: String,
        formStateBlock: @escaping (Snapshot) -> String,
        parse: @escaping (String) -> (text: String, patch: Patch?),
        aiService: (any AIServiceProtocol)?,
        gate: EmbeddedStreamGate?
    ) {
        self.greeting = greeting
        engine = EmbeddedChatEngine(
            spec: ChatSurfaceSpec(
                key: EmbeddedChatKey(contextType: "setup", contextID: contextID, conversationID: nil),
                persistence: .memory, toolAccess: .draftOnly, systemPrompt: { systemPrompt }, emptyHint: ""),
            store: MemoryEmbeddedChatStore(),
            aiService: aiService ?? WatchtowerAIService(),
            gate: gate ?? EmbeddedStreamGate(),
            provider: Constants.aiProviderID()
        )
        engine.update(spec: ChatSurfaceSpec(
            key: engine.spec.key,
            persistence: .memory,
            // A setup panel acts only through the settings block → form patch,
            // never through a tool (review-rules "The assistant & chat contracts").
            toolAccess: .draftOnly,
            systemPrompt: { systemPrompt },
            // The form changes between turns (the owner types, patches land),
            // so EVERY turn carries a fresh snapshot — which also keeps a
            // resumed session (system prompt dropped by CLI --resume) in context.
            turnPrompt: { [weak self] input in
                guard let snapshot = self?.currentSnapshot() else { return input.text }
                return "\(formStateBlock(snapshot))\n\n\(input.text)"
            },
            postTurn: { [weak self] input in
                let parsed = parse(input.reply)
                if let patch = parsed.patch { self?.onApplySettings?(patch) }
                let text = parsed.text.isEmpty && parsed.patch != nil ? filledPlaceholder : parsed.text
                return ChatPostTurnResult(displayText: text)
            },
            emptyHint: ""
        ))
        engine.onTurnFinished = { [weak self] outcome in
            switch outcome {
            case .failed(_, let message), .notStarted(let message): self?.errorMessage = message
            case .completed: self?.errorMessage = nil
            case .stopped: break
            }
        }
    }

    var messages: [ChatMessage] {
        engine.messages.map { item in
            let live = engine.liveTurn.flatMap { $0.messageID == item.id ? $0 : nil }
            let row = item.message.toChatMessage()
            return ChatMessage(id: row.id, role: row.role, text: live?.fullText ?? row.text,
                               timestamp: row.timestamp, isStreaming: live != nil, turnID: row.turnID)
        }
    }

    var isStreaming: Bool { engine.isBusy }

    var inputText: String {
        get { engine.draft }
        set { engine.draft = newValue }
    }

    /// Local greeting shown when the panel opens — no AI call.
    func seedGreetingIfNeeded() {
        guard engine.messages.isEmpty else { return }
        engine.appendLocal(role: "assistant", text: greeting)
    }

    func send(snapshot: Snapshot) {
        lastSnapshot = snapshot
        errorMessage = nil
        engine.sendDraft()
    }

    /// Feeds a failed connect error into the chat as a visible owner turn so
    /// the assistant can explain it in plain words.
    func sendConnectionError(_ error: String, snapshot: Snapshot) {
        guard !isStreaming else { return }
        lastSnapshot = snapshot
        errorMessage = nil
        engine.send("Connecting failed with this error:\n\(error)\n\nWhat should I do?")
    }

    func cancelStream() {
        engine.stop()
    }

    private func currentSnapshot() -> Snapshot? {
        if let snapshotProvider {
            let snapshot = snapshotProvider()
            lastSnapshot = snapshot
            return snapshot
        }
        return lastSnapshot
    }
}
