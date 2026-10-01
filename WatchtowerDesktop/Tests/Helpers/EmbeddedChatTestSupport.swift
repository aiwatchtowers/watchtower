import Foundation
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore

/// An engine for a surface's spec over the test database, streaming from
/// `ai` — what `AppState.embeddedChatCenter` would hand the surface's view.
@MainActor
func makeSurfaceEngine(_ spec: ChatSurfaceSpec, dbPool: DatabasePool, ai: any AIServiceProtocol) -> EmbeddedChatEngine {
    let store: EmbeddedChatStore
    switch spec.persistence {
    case .database(let conversationID):
        store = DatabaseEmbeddedChatStore(dbPool: dbPool, conversationID: conversationID)
    case .memory:
        store = MemoryEmbeddedChatStore()
    }
    return EmbeddedChatEngine(spec: spec, store: store, aiService: ai, gate: EmbeddedStreamGate())
}

/// Polls on the main actor until `condition` holds (a 5 s deadline).
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < .seconds(5) {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))  // polling interval; cancellation ends the test anyway
    }
    return condition()
}
