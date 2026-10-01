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
    /// The form as it is now — read for every turn (composer, Retry, a
    /// connection error), so the assistant always sees the current state.
    /// Set by the sheet next to `onApplySettings`.
    @ObservationIgnored var snapshotProvider: (() -> Snapshot)?
    /// The latest turn's failure; cleared by the next completed turn.
    var errorMessage: String?

    private let greeting: String
    private let connectionErrorLead: String

    /// `parse` splits a reply into the text to show and the settings patch
    /// (nil when the reply carries none, or a malformed block).
    init(
        contextID: String,
        greeting: String,
        systemPrompt: String,
        connectionErrorLead: String,
        formStateBlock: @escaping (Snapshot) -> String,
        parse: @escaping (String) -> (text: String, patch: Patch?),
        aiService: (any AIServiceProtocol)?,
        gate: EmbeddedStreamGate?
    ) {
        self.greeting = greeting
        self.connectionErrorLead = connectionErrorLead
        let key = EmbeddedChatKey(contextType: "setup", contextID: contextID, conversationID: nil)
        engine = EmbeddedChatEngine(
            spec: ChatSurfaceSpec(key: key, persistence: .memory, toolAccess: .draftOnly,
                                  systemPrompt: { systemPrompt }, emptyHint: ""),
            store: MemoryEmbeddedChatStore(),
            aiService: aiService ?? WatchtowerAIService(),
            gate: gate ?? EmbeddedStreamGate(),
            provider: Constants.aiProviderID()
        )
        engine.update(spec: ChatSurfaceSpec(
            key: key,
            persistence: .memory,
            // The panel changes local state only through the settings block →
            // form patch the owner sees, never through a tool, so no tool mode.
            toolAccess: .draftOnly,
            systemPrompt: { systemPrompt },
            // The form changes between turns (the owner types, patches land),
            // so EVERY turn carries a fresh snapshot — which also keeps a
            // resumed session (system prompt dropped by CLI --resume) in context.
            turnPrompt: { [weak self] input in
                guard let snapshot = self?.snapshotProvider?() else {
                    NSLog("SetupAssistantChat[%@]: a turn without the form state", contextID)
                    return input.text
                }
                return "\(formStateBlock(snapshot))\n\n\(input.text)"
            },
            postTurn: { [weak self] input in
                let parsed = parse(input.reply)
                if let patch = parsed.patch {
                    self?.onApplySettings?(patch)
                    return ChatPostTurnResult(displayText: parsed.text.isEmpty
                        ? "(filled in the settings on the left)" : parsed.text)
                }
                if parsed.text.isEmpty {
                    // Only a settings block that could not be read.
                    NSLog("SetupAssistantChat[%@]: a settings block could not be read", contextID)
                    return ChatPostTurnResult(displayText: "(couldn't apply the suggested settings — fill them in on the left)")
                }
                return ChatPostTurnResult(displayText: parsed.text)
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

    var messages: [ChatMessage] { engine.chatMessages }
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

    /// Sends the composer's text (what the panel's composer does).
    func send() {
        engine.sendDraft()
    }

    /// Feeds a failed connect error into the chat as a visible owner turn so
    /// the assistant can explain it in plain words.
    func sendConnectionError(_ error: String) {
        guard engine.send("\(connectionErrorLead)\n\(error)\n\nWhat should I do?") else {
            NSLog("SetupAssistantChat: a connection error was not sent (a reply is under way)")
            return
        }
    }
}
