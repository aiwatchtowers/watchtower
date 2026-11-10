import Foundation
import GRDB
import Observation
import os
import WatchtowerCore

private let tuningChatLog = Logger(subsystem: Constants.bundleID, category: "tuning-chat")

/// One open tuning panel (spec 2026-11-03 §4.1): the engine of the shown
/// conversation (from the app-wide `EmbeddedChatCenter`, so a turn keeps
/// streaming after the panel goes away), the workbench's recent
/// conversations and the proposal cards of the shown one. The
/// `AutomationEditorChat` shape: made when the panel opens, `close()`d when
/// it goes.
///
/// AGENT-04: the tool access is `decideTools()` — the catalog's kind of the
/// current provider, never a provider name (LLMTRANSPORT-01) — read again
/// before each owner turn and whenever the catalog finishes a read; when it
/// changed, the spec is rebuilt before the turn starts. An HTTP provider
/// (ollama) always decides `false` (owner, ask #1132, spec D52); every turn
/// is a `tuning.chat` call either way (D53). Accept / Decline / Roll Back go
/// through `CoachCenter` and are not gated on the provider.
@MainActor
@Observable
final class TuningChat {
    let workbenchID: Int64
    private(set) var engine: EmbeddedChatEngine
    private(set) var conversationID: Int64
    private(set) var toolsAvailable: Bool
    /// The workbench's newest conversations (`TuningChatSurface.recent`).
    private(set) var recent: [ChatConversation] = []
    private(set) var cards = TuningFeedCards.build(actions: [], proposals: [])
    /// Why the last read of the conversations or cards failed; nil after one
    /// that worked.
    private(set) var loadError: String?

    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let center: EmbeddedChatCenter
    @ObservationIgnored private let coach: CoachCenter?
    @ObservationIgnored private let decideTools: @MainActor () -> Bool
    @ObservationIgnored private let period: @MainActor () -> AgentAnalyticsCenter.Period
    /// The spec's `onWillSend` is built before `self` exists; it reaches the
    /// controller through this.
    @ObservationIgnored private let hook: WillSendHook
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var catalogObserver: NSObjectProtocol?

    init(
        workbenchID: Int64,
        conversationID: Int64,
        dbPool: DatabasePool,
        center: EmbeddedChatCenter,
        coach: CoachCenter?,
        decideTools: @escaping @MainActor () -> Bool = { TuningChatSurface.toolsAvailable(provider: nil) },
        period: @escaping @MainActor () -> AgentAnalyticsCenter.Period
    ) {
        self.workbenchID = workbenchID
        self.conversationID = conversationID
        self.dbPool = dbPool
        self.center = center
        self.coach = coach
        self.decideTools = decideTools
        self.period = period
        let hook = WillSendHook()
        self.hook = hook
        let tools = decideTools()
        toolsAvailable = tools
        let spec = Self.makeSpec(workbenchID: workbenchID, conversationID: conversationID, tools: tools,
                                 period: period, hook: hook)
        engine = center.engine(for: spec)
        hook.chat = self
        center.markShown(spec.key)
        attach(engine)
        catalogObserver = NotificationCenter.default.addObserver(
            forName: AIModelCatalog.didLoadNotification, object: AIModelCatalog.shared, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshToolAccess() }
        }
    }

    // MARK: - Panel

    /// The panel went away: the engine stays in the center (a running turn
    /// finishes), only this view of it stops.
    func close() {
        guard !closed else { return }
        closed = true
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
        catalogObserver = nil
        center.markHidden(engine.spec.key)
    }

    /// Shows another conversation of the workbench (the recent list).
    func switchTo(_ conversationID: Int64) {
        guard !closed, conversationID != self.conversationID else { return }
        center.markHidden(engine.spec.key)
        self.conversationID = conversationID
        cards = TuningFeedCards.build(actions: [], proposals: [])
        loadError = nil
        engine = center.engine(for: currentSpec())
        center.markShown(engine.spec.key)
        attach(engine)
        Task { await refreshCards() }
    }

    /// **New**: another conversation for the workbench, shown at once.
    func startNew() async {
        do {
            let id = try await TuningChatSurface.newConversation(dbPool: dbPool, workbenchID: workbenchID)
            switchTo(id)
        } catch {
            loadError = "Couldn't start a new tuning chat: \(error.localizedDescription)"
        }
    }

    /// A starter: sent at once, or put in the composer when it needs the
    /// owner's text.
    func send(starter: ChatStarterPrompt) {
        if starter.sendsImmediately {
            engine.send(starter.text)
        } else {
            engine.draft = starter.text
        }
    }

    // MARK: - Cards

    /// Re-reads the recent list and the shown conversation's cards (its
    /// `agent_actions` and chat proposals), and asks the coach for its
    /// proposal list so a card shows the proposal's current state.
    func refreshCards() async {
        let conversationID = self.conversationID
        let workbenchID = self.workbenchID
        do {
            let (actions, proposals, recent) = try await dbPool.read { db in
                (try AgentActionQueries.fetchByConversation(db, conversationID: conversationID),
                 try TuningChatSurface.proposals(db, conversationID: conversationID),
                 try TuningChatSurface.recent(db, workbenchID: workbenchID))
            }
            self.recent = recent
            // A switch meanwhile: the cards read belong to another conversation.
            if conversationID == self.conversationID {
                cards = TuningFeedCards.build(actions: actions, proposals: proposals)
            }
            loadError = nil
        } catch {
            loadError = "Couldn't read the tuning chat's proposals: \(error.localizedDescription)"
        }
        coach?.refreshProposals()
    }

    // MARK: - Tool access

    /// Before each owner turn (the spec's `willSend`) and after a catalog
    /// read: AGENT-04's tool access is decided again and, when it changed,
    /// the engine gets the rebuilt spec before the turn reads it.
    func refreshToolAccess() {
        guard !closed else { return }
        decideToolAccess()
    }

    /// A turn of `conversationID` is about to start: only the shown
    /// conversation's spec is this controller's to rebuild (an engine the
    /// panel left keeps the spec it has).
    private func willSend(conversationID: Int64) {
        guard conversationID == self.conversationID else { return }
        refreshToolAccess()
    }

    private func decideToolAccess() {
        let now = decideTools()
        guard now != toolsAvailable else { return }
        toolsAvailable = now
        engine = center.engine(for: currentSpec())
    }

    // MARK: - Private

    private func currentSpec() -> ChatSurfaceSpec {
        Self.makeSpec(workbenchID: workbenchID, conversationID: conversationID, tools: toolsAvailable,
                      period: period, hook: hook)
    }

    private static func makeSpec(
        workbenchID: Int64,
        conversationID: Int64,
        tools: Bool,
        period: @escaping @MainActor () -> AgentAnalyticsCenter.Period,
        hook: WillSendHook
    ) -> ChatSurfaceSpec {
        TuningChatSurface.spec(workbenchID: workbenchID, conversationID: conversationID, tools: tools,
                               period: period) { [weak hook] in hook?.chat?.willSend(conversationID: conversationID) }
    }

    /// Every panel on the engine hears its turn end: the engine has one
    /// `onTurnFinished`, so it goes to the engine's `TuningTurnFanOut`.
    private func attach(_ engine: EmbeddedChatEngine) {
        TuningTurnFanOut.of(engine, dbPool: dbPool, conversationID: conversationID).add(self)
    }

    /// A turn of `conversationID` ended (its title is already written):
    /// the cards follow when it is the conversation on show.
    fileprivate func turnFinished(conversationID: Int64) async {
        guard !closed, conversationID == self.conversationID else { return }
        await refreshCards()
    }
}

/// One per tuning engine: titles the conversation after each turn — whether
/// or not a panel is still open — then tells every live panel on it.
@MainActor
private final class TuningTurnFanOut {
    private static let byEngine = NSMapTable<EmbeddedChatEngine, TuningTurnFanOut>.weakToStrongObjects()

    private let dbPool: DatabasePool
    private let conversationID: Int64
    private var panels: [WeakPanel] = []

    private struct WeakPanel {
        weak var chat: TuningChat?
    }

    private init(dbPool: DatabasePool, conversationID: Int64) {
        self.dbPool = dbPool
        self.conversationID = conversationID
    }

    static func of(_ engine: EmbeddedChatEngine, dbPool: DatabasePool, conversationID: Int64) -> TuningTurnFanOut {
        if let existing = byEngine.object(forKey: engine) { return existing }
        let fanOut = TuningTurnFanOut(dbPool: dbPool, conversationID: conversationID)
        byEngine.setObject(fanOut, forKey: engine)
        engine.onTurnFinished = { _ in Task { await fanOut.turnFinished() } }
        return fanOut
    }

    func add(_ chat: TuningChat) {
        panels.removeAll { $0.chat == nil || $0.chat === chat }
        panels.append(WeakPanel(chat: chat))
    }

    private func turnFinished() async {
        let conversationID = self.conversationID
        do {
            try await dbPool.write { db in
                try TuningChatSurface.setTitleIfEmpty(db, conversationID: conversationID)
            }
        } catch {
            // Cosmetic: the chat stays untitled until a later turn titles it.
            tuningChatLog.error(
                "titling tuning conversation \(conversationID): \(error.localizedDescription, privacy: .private)")
        }
        for panel in panels {
            await panel.chat?.turnFinished(conversationID: conversationID)
        }
    }
}

/// The spec's `onWillSend` → the controller, which does not exist yet when
/// its first spec is built.
@MainActor
private final class WillSendHook {
    weak var chat: TuningChat?
}
