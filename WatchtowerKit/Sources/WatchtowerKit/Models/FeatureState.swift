import Foundation
import GRDB

/// One `feature_state` slice row: a desktop Feature Manager entry mirrored
/// to the phone (id → effective enabled/disabled). The phone is a satellite —
/// it renders this state and never writes it back.
public struct FeatureState: FetchableRecord, Identifiable, Equatable, Sendable {
    /// The Go registry's stable kebab-case feature id (e.g. "secretary-inbox").
    public let id: String
    public let enabled: Bool

    public init(row: Row) {
        id = row["id"] ?? ""
        // Fail open: a malformed row without the flag counts as enabled,
        // matching the absent-slice default.
        enabled = row["enabled"] ?? true
    }

    public init(id: String, enabled: Bool) {
        self.id = id
        self.enabled = enabled
    }
}

/// Visibility semantics over a set of `FeatureState` rows, shared by every
/// phone surface that gates on a feature id.
///
/// Fail-open by construction: only an id explicitly synced as disabled
/// hides anything. An empty replica (older desktop that never publishes the
/// kind), an id the slice does not mention, and a surface mapped to no
/// feature id (`nil`) are all visible — backward compatible in both
/// directions (unknown ids in the slice are simply never looked up).
public struct FeatureVisibility: Equatable, Sendable {
    private let disabledFeatureIDs: Set<String>

    /// The absent-slice default: everything visible.
    public static let allVisible = Self(states: [])

    public init(states: [FeatureState]) {
        disabledFeatureIDs = Set(states.filter { !$0.enabled }.map(\.id))
    }

    /// `nil` = the surface maps to no registry feature — always visible.
    public func isVisible(featureID: String?) -> Bool {
        guard let featureID else { return true }
        return !disabledFeatureIDs.contains(featureID)
    }
}
