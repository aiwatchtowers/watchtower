import Foundation

/// The Automations tab's three rule sections. The chosen one is a per-viewer
/// convenience kept in `UserDefaults` under `storageKey`.
package enum AutomationsSection: String, CaseIterable, Sendable {
    case automations, reactions, tracks

    package static let storageKey = "automations.section"

    package var title: String {
        switch self {
        case .automations: "Automations"
        case .reactions: "Reactions"
        case .tracks: "Tracks"
        }
    }

    /// The sections to offer: Tracks drops out while its sidebar tab is hidden.
    package static func visible(tracksVisible: Bool) -> [Self] {
        allCases.filter { $0 != .tracks || tracksVisible }
    }

    /// A stored raw value to the section to show: unknown, missing or no
    /// longer visible falls back to Automations.
    package static func resolve(stored: String?, tracksVisible: Bool) -> Self {
        guard let stored, let section = Self(rawValue: stored),
              visible(tracksVisible: tracksVisible).contains(section) else { return .automations }
        return section
    }
}
