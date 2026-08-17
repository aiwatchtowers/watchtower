import Foundation
import GRDB
import Observation
import WatchtowerKit

/// The phone's window onto the desktop Feature Manager: observes the
/// `feature_state` slice and answers "is this surface visible?" for every
/// feature-gated tab and Today section. Strictly read-only — the phone is a
/// SATELLITE of the desktop manager and never toggles anything (owner
/// decision, 2026-08-17 reanimation plan Workstream 3).
///
/// Owned by `RootTabView` (the root never leaves the hierarchy, so the
/// observation survives all navigation) and injected into the environment
/// for the Today sections.
@MainActor
@Observable
final class FeatureGate {
    /// Fail-open until the first observation fires — an empty replica
    /// (older desktop that never publishes the kind) shows everything.
    private(set) var visibility: FeatureVisibility = .allVisible

    private var cancellable: AnyDatabaseCancellable?

    /// Every feature-gated surface on the phone. Tabs missing from
    /// `featureIDBySurface` (Today, Settings) and surfaces mapped to no
    /// registry feature are never hideable.
    enum Surface: Hashable {
        case tab(RootTabView.Tab)
        case todayBriefing
        case todayDayPlan
    }

    /// THE one surface → registry-feature-id lookup (ids from
    /// internal/features/registry.go). Future surfaces (e.g. digests) join
    /// this table instead of growing ad-hoc checks. The recordings entry
    /// under Today maps to no registry feature today — always visible, so
    /// it has no row here.
    private nonisolated static let featureIDBySurface: [Surface: String] = [
        .tab(.tasks): "targets",
        .tab(.tracks): "tracks",
        .tab(.inbox): "secretary-inbox",
        .tab(.chat): "chat",
        .todayBriefing: "briefing",
        .todayDayPlan: "day-plan"
    ]

    func start(store: ReplicaStore) {
        guard cancellable == nil else { return }
        cancellable = ReplicaObserver.observe(FeatureState.self, kind: .featureState, in: store) { [weak self] states in
            self?.visibility = FeatureVisibility(states: states)
        }
    }

    func isVisible(_ surface: Surface) -> Bool {
        Self.isVisible(surface, visibility: visibility)
    }

    /// Desktop navigation-fallback semantics: a selection whose tab is
    /// hidden falls back to Today.
    func resolvedSelection(_ selection: RootTabView.Tab) -> RootTabView.Tab {
        Self.resolvedSelection(selection, visibility: visibility)
    }

    // Pure static cores — nonisolated so the unit tests need no observation
    // machinery (and no actor hop).

    nonisolated static func isVisible(_ surface: Surface, visibility: FeatureVisibility) -> Bool {
        visibility.isVisible(featureID: featureIDBySurface[surface])
    }

    nonisolated static func resolvedSelection(
        _ selection: RootTabView.Tab,
        visibility: FeatureVisibility
    ) -> RootTabView.Tab {
        isVisible(.tab(selection), visibility: visibility) ? selection : .today
    }
}
