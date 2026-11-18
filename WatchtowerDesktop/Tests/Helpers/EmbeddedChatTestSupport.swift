import Foundation
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// An engine for a surface's spec over the test database, streaming from
/// `ai` — what `AppState.embeddedChatCenter` would hand the surface's view.
@MainActor
func makeSurfaceEngine(
    _ spec: ChatSurfaceSpec,
    dbPool: DatabasePool,
    ai: any AIServiceProtocol,
    gate: EmbeddedStreamGate? = nil
) -> EmbeddedChatEngine {
    let store: EmbeddedChatStore
    switch spec.persistence {
    case .database(let conversationID):
        store = DatabaseEmbeddedChatStore(dbPool: dbPool, conversationID: conversationID)
    case .memory:
        store = MemoryEmbeddedChatStore()
    }
    return EmbeddedChatEngine(spec: spec, store: store, aiService: ai, gate: gate ?? EmbeddedStreamGate())
}

/// Waits on the main actor until `condition` holds — re-checked once per main-actor turn, no clock and no
/// deadline (`untilTurn`). Always returns true (call sites assert it).
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    await untilTurn(condition)
    return true
}
