import Foundation
import WatchtowerCore

extension AppState {
    /// Analytics' tuning panel for one workbench, on its newest tuning
    /// conversation (created on first use); the engine comes from
    /// `embeddedChatCenter`, so a turn outlives the panel. Nil while the
    /// database is not open.
    func makeTuningChat(
        workbenchID: Int64,
        period: @escaping @MainActor () -> AgentAnalyticsCenter.Period
    ) async throws -> TuningChat? {
        guard let pool = databaseManager?.dbPool else { return nil }
        let conversationID = try await TuningChatSurface.latestOrNewConversation(dbPool: pool, workbenchID: workbenchID)
        // Before the catalog's first read this decides draft-only; the
        // controller decides again on `AIModelCatalog.didLoadNotification`.
        let chat = TuningChat(workbenchID: workbenchID, conversationID: conversationID, dbPool: pool,
                              center: embeddedChatCenter, coach: coachCenter,
                              decideTools: { TuningChatSurface.toolsAvailable(provider: nil) }, period: period)
        await chat.refreshCards()
        return chat
    }
}

extension AppState {
    /// What a removed workbench takes with it: its code questions and
    /// usages, its review, its tuning panel and the panel's chat engines.
    func wireWorkbenchRemoved(_ vm: WorkbenchesViewModel) {
        vm.onWorkbenchRemoved = { [weak self, weak codeQuestionCenter, weak codeUsagesCenter, weak vm] id in
            codeQuestionCenter?.workbenchRemoved(id)
            codeUsagesCenter?.workbenchRemoved(id)
            vm?.reviewer?.workbenchRemoved(id)
            vm?.tuningOpen.remove(id)
            vm?.analyticsScroll[id] = nil
            self?.embeddedChatCenter.dropContext(type: TuningChatSurface.contextType, id: String(id))
        }
    }
}
