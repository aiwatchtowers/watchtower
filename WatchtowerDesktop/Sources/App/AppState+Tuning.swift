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
        let chat = TuningChat(workbenchID: workbenchID, conversationID: conversationID, dbPool: pool,
                              center: embeddedChatCenter, coach: coachCenter,
                              decideTools: { TuningChatSurface.toolsAvailable(provider: nil) }, period: period)
        await chat.refreshCards()
        return chat
    }
}
