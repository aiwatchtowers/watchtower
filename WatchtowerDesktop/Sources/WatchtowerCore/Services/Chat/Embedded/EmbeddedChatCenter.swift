import Foundation
import Observation

/// App-wide home of the embedded chats' engines (one per `EmbeddedChatKey`),
/// held on `AppState` so a turn keeps streaming after its screen closes or
/// its section collapses (review-rules "Lifecycle & state"). Views fetch the
/// engine here and report when they show or hide it.
///
/// An engine is released when it is idle and no view has shown it for
/// `idleTTL` (5 minutes by default), when its context is deleted (`dropContext`), or explicitly
/// (`release` — onboarding and the setup sheets on close). A busy engine is
/// never released by the sweep.
@MainActor
@Observable
package final class EmbeddedChatCenter {
    package typealias EngineFactory = (ChatSurfaceSpec, EmbeddedStreamGate) -> EmbeddedChatEngine

    package let gate: EmbeddedStreamGate
    @ObservationIgnored private var engines: [EmbeddedChatKey: EmbeddedChatEngine] = [:]
    /// Keys a view currently shows, with how many views show each.
    @ObservationIgnored private var shownCount: [EmbeddedChatKey: Int] = [:]
    @ObservationIgnored private var hiddenSince: [EmbeddedChatKey: Date] = [:]
    @ObservationIgnored private let makeEngine: EngineFactory
    @ObservationIgnored private let clock: () -> Date
    private let idleTTL: TimeInterval

    package init(
        gate: EmbeddedStreamGate? = nil,
        idleTTL: TimeInterval = 300,
        clock: @escaping () -> Date = Date.init,
        makeEngine: @escaping EngineFactory
    ) {
        self.gate = gate ?? EmbeddedStreamGate()
        self.idleTTL = idleTTL
        self.clock = clock
        self.makeEngine = makeEngine
    }

    package var count: Int { engines.count }

    /// The engine for `spec.key`, created on first use; the same instance
    /// afterwards (a later spec for the same key is ignored).
    package func engine(for spec: ChatSurfaceSpec) -> EmbeddedChatEngine {
        if let existing = engines[spec.key] { return existing }
        let engine = makeEngine(spec, gate)
        engines[spec.key] = engine
        hiddenSince[spec.key] = clock()
        return engine
    }

    package func loaded(_ key: EmbeddedChatKey) -> EmbeddedChatEngine? { engines[key] }

    package func markShown(_ key: EmbeddedChatKey) {
        shownCount[key, default: 0] += 1
        hiddenSince[key] = nil
    }

    package func markHidden(_ key: EmbeddedChatKey) {
        let remaining = max(0, (shownCount[key] ?? 0) - 1)
        shownCount[key] = remaining == 0 ? nil : remaining
        if remaining == 0 { hiddenSince[key] = clock() }
    }

    /// Releases idle engines no view has shown for `idleTTL`.
    package func sweep(now: Date? = nil) {
        let now = now ?? clock()
        for (key, engine) in engines where shownCount[key] == nil && !engine.isBusy {
            guard let since = hiddenSince[key], now.timeIntervalSince(since) >= idleTTL else { continue }
            remove(key, quietly: false)
        }
    }

    /// The target/track/idea was deleted: its engines stop without a word
    /// (their rows went with the conversation).
    package func dropContext(type: String, id: String) {
        for key in engines.keys where key.contextType == type && key.contextID == id {
            remove(key, quietly: true)
        }
    }

    /// A sheet or window that owns its chat closed.
    package func release(_ key: EmbeddedChatKey) {
        remove(key, quietly: false)
    }

    /// App quit: every running reply keeps what streamed, as `partial`.
    package func finishAllAsPartial() {
        for engine in engines.values { engine.finishAsPartial() }
    }

    private func remove(_ key: EmbeddedChatKey, quietly: Bool) {
        engines[key]?.shutdown(quietly: quietly)
        engines[key] = nil
        shownCount[key] = nil
        hiddenSince[key] = nil
    }
}
