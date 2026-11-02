import Foundation

/// Where the one-time hand-over of Mobile to the Go hub stands (go hub plan
/// 3 Task 22, spec §12.1–§12.2), as Settings → Mobile shows it. The copy
/// lives here, pinned by tests.
///
/// Task 23 codes against Task 22's planned shape; Task 22 owns this type
/// (its driver produces it) and its version wins on merge.
package enum HubAdoptionState: Equatable, Sendable {
    case notNeeded
    case inProgress(step: String)
    case failed(reason: String)
    case done

    package var title: String {
        switch self {
        case .notNeeded, .done: "Mobile"
        case .inProgress: "Moving Mobile to the new version…"
        case .failed: "Mobile could not move to the new version"
        }
    }

    package var detail: String? {
        switch self {
        case .notNeeded, .done: nil
        case .inProgress: "Your phones stay linked; this takes a moment."
        case .failed(let reason):
            switch reason {
            case "no_keys": "This Mac's encryption keys are missing. Your phones need to be linked again."
            case "swift_schema": "The old Mobile data has a format this version does not know. Nothing was changed."
            default: "Mobile stays off until it has moved. Nothing was changed."
            }
        }
    }

    package var retryTitle: String? {
        if case .failed = self { return "Retry" }
        return nil
    }
}
