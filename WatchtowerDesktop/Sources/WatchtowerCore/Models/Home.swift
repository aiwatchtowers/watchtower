import Foundation

// MARK: - Getting ready

/// How a Getting ready card reads its readiness.
package enum ReadinessTone: Equatable, Sendable {
    case ready, preparing, waiting, error
}

/// One tracked feature in the Getting ready zone.
package struct GettingReadyCard: Equatable, Sendable {
    package let feature: ReadinessFeature
    package let copy: FeatureCardCopy
    /// nil = no line (before evaluation, or the owner gate).
    package let readiness: Readiness?

    package init(feature: ReadinessFeature, copy: FeatureCardCopy, readiness: Readiness?) {
        self.feature = feature
        self.copy = copy
        self.readiness = readiness
    }

    package var tone: ReadinessTone {
        switch readiness {
        case .ready: .ready
        case .preparing: .preparing
        case .error: .error
        case .off, .needsSource, .waitingForSync, .scheduled, nil: .waiting
        }
    }

    /// Ready or error: nothing more will happen to this card on its own.
    package var isTerminal: Bool { tone == .ready || tone == .error }
}

/// A source the zone asks to connect, with the features waiting on it.
package struct GettingReadySourceRow: Equatable, Sendable {
    package let source: ReadinessSource
    /// Pipeline order.
    package let features: [ReadinessFeature]

    package init(source: ReadinessSource, features: [ReadinessFeature]) {
        self.source = source
        self.features = features
    }
}

package enum GettingReadyZone: Equatable, Sendable {
    case hidden
    /// "Everything's ready", this launch only.
    case allReady
    case shown(cards: [GettingReadyCard], sourceRows: [GettingReadySourceRow])
}

/// Persisted per install: the owner's ×, when the zone was first shown,
/// when it completed.
package struct GettingReadyMemory: Equatable, Sendable {
    package var hiddenByOwner: Bool
    package var firstShownAt: Date?
    package var completedAt: Date?

    package init(hiddenByOwner: Bool = false, firstShownAt: Date? = nil, completedAt: Date? = nil) {
        self.hiddenByOwner = hiddenByOwner
        self.firstShownAt = firstShownAt
        self.completedAt = completedAt
    }
}

/// One `GettingReadyPolicy.step` result.
package struct GettingReadyStep: Equatable, Sendable {
    package let zone: GettingReadyZone
    /// What to persist.
    package let memory: GettingReadyMemory
    /// Launch-scoped; fed back into the next step.
    package let sawUnready: Bool

    package init(zone: GettingReadyZone, memory: GettingReadyMemory, sawUnready: Bool) {
        self.zone = zone
        self.memory = memory
        self.sawUnready = sawUnready
    }
}
