import Foundation

/// Where the one-time hand-over of Mobile to the Go hub stands (go hub plan 3
/// Task 22, spec §12.1–§12.2, mockup sections 4–6). Every string Settings →
/// Mobile shows for it lives here, pinned by `HubAdoptionStateTests`; the
/// owner accepted this copy (ask #906).
package enum HubAdoptionState: Equatable, Sendable {
    /// The adoption state is being read (`hub adopt --status`).
    case checking
    /// Nothing to hand over: no Swift hub state on this Mac, or one the Go
    /// hub refuses as a later `MobileHub` (no Retry then).
    case notNeeded
    /// The hand-over runs. `step` is the Go adoption step the run starts
    /// from (`copy` … `done`), `keys` while the keys go over, `cleanup` while
    /// the Desktop deletes its own items.
    case inProgress(step: String)
    /// Stopped with an error class; Mobile stays off until **Retry**.
    case failed(reason: String)
    /// Handed over: the Go hub owns Mobile.
    case done

    package static let sectionTitle = "Mobile"
    package static let checkingTitle = "Loading…"
    package static let movingTitle = "Moving Mobile to the new version…"
    package static let failedTitle = "Mobile could not move to the new version"
    package static let doneTitle = "Mobile moved to the new version"
    package static let retryButtonTitle = "Retry"
    /// The hand-over's steps as the owner sees them: copy, verify, move,
    /// migrate, keys.
    package static let stepCount = 5

    package var title: String {
        switch self {
        case .checking: Self.checkingTitle
        case .notNeeded: ""
        case .inProgress: Self.movingTitle
        case .failed: Self.failedTitle
        case .done: Self.doneTitle
        }
    }

    package var detail: String? {
        switch self {
        case let .inProgress(step):
            "Step \(Self.stepNumber(step)) of \(Self.stepCount). Your phones stay linked; this takes a moment."
        case let .failed(reason): Self.reasonText(reason)
        default: nil
        }
    }

    /// The narrow-width line under the title (mockup section 5).
    package var compactDetail: String? {
        guard case let .inProgress(step) = self else { return detail }
        return "Step \(Self.stepNumber(step)) of \(Self.stepCount)."
    }

    package var retryTitle: String? {
        if case .failed = self { return Self.retryButtonTitle }
        return nil
    }

    /// The progress bar's value while the hand-over runs.
    package var progress: Double? {
        guard case let .inProgress(step) = self else { return nil }
        return Double(Self.stepNumber(step)) / Double(Self.stepCount)
    }

    /// Settings → Mobile shows the hand-over instead of its own rows.
    package var isShown: Bool {
        switch self {
        case .checking, .inProgress, .failed: true
        case .notNeeded, .done: false
        }
    }

    package var isError: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The owner's step for a Go adoption step (or `keys`/`cleanup`).
    package static func stepNumber(_ step: String) -> Int {
        switch step {
        case "verify": 2
        case "rename": 3
        case "migrate", "recordings", "settings", "transport", "moved", "done": 4
        case "keys", "cleanup": 5
        default: 1 // copy, or not started yet
        }
    }

    /// The line under the failure title for an error class: the Go hub's
    /// (`hub adopt`) and the driver's own (`no_keys`, `keychain_unavailable`,
    /// `no_hub_id`, `no_cli`). An unknown class reads as `failed`.
    package static func reasonText(_ reason: String) -> String {
        reasonTexts[reason] ?? genericFailure
    }

    package static let genericFailure = "Something went wrong during the move. Retry continues where it stopped."

    package static let reasonTexts: [String: String] = [
        "swift_schema": "The old Mobile data has a format this version does not know. Nothing was changed.",
        "swift_corrupt": "The old Mobile data is damaged. Nothing was changed.",
        "swift_hub_id": "The old Mobile data has no hub identity. Nothing was changed.",
        "swift_busy": "The old Mobile hub was still writing. Retry in a moment.",
        "no_hub_id": "The old Mobile data has no hub identity. Nothing was changed.",
        "no_keys": "This Mac's encryption keys are missing. Your phones need to be linked again.",
        "wrong_keys": "This Mac's encryption keys do not open the old Mobile data. Nothing was changed.",
        "bad_keys": "This Mac's encryption keys could not be read. Nothing was changed.",
        "keychain_unavailable": "The Keychain could not be read. Unlock this Mac and retry.",
        "keychain_refused": "The new version could not keep the encryption keys in the Keychain.",
        "cleanup_failed": "A leftover copy of the encryption keys could not be removed. Retry removes it.",
        "no_sidecar": "The moved Mobile data was not found. Retry continues where it stopped.",
        "adoption_unfinished": "The move stopped before it finished. Retry continues where it stopped.",
        "not_adopted": "The move stopped before it finished. Retry continues where it stopped.",
        "locked": "Mobile is busy in another Watchtower process. Retry in a moment.",
        "no_cli": "The watchtower command-line tool was not found. Reinstall Watchtower and retry.",
        "failed": genericFailure
    ]
}

/// `watchtower hub adopt --status --json` (pinned keys, cmd/hub_adopt.go):
/// the only place Desktop reads the adoption state from.
package struct HubAdoptStatus: Decodable, Equatable, Sendable {
    package struct PendingRecording: Decodable, Equatable, Sendable {
        package let uploadID: String
        package let audioName: String

        package init(uploadID: String, audioName: String) {
            self.uploadID = uploadID
            self.audioName = audioName
        }

        enum CodingKeys: String, CodingKey {
            case uploadID = "upload_id"
            case audioName = "audio_name"
        }
    }

    package let step: String
    package let error: String
    package let hubID: String
    /// none|staged|adopted|confirmed
    package let identity: String
    /// present|ignored|absent
    package let swiftState: String
    package let pendingRecordings: [PendingRecording]

    package init(
        step: String = "",
        error: String = "",
        hubID: String = "",
        identity: String = "none",
        swiftState: String = "absent",
        pendingRecordings: [PendingRecording] = []
    ) {
        self.step = step
        self.error = error
        self.hubID = hubID
        self.identity = identity
        self.swiftState = swiftState
        self.pendingRecordings = pendingRecordings
    }

    enum CodingKeys: String, CodingKey {
        case step, error, identity
        case hubID = "hub_id"
        case swiftState = "swift_state"
        case pendingRecordings = "pending_recordings"
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = try c.decodeIfPresent(String.self, forKey: .step) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        hubID = try c.decodeIfPresent(String.self, forKey: .hubID) ?? ""
        identity = try c.decodeIfPresent(String.self, forKey: .identity) ?? "none"
        swiftState = try c.decodeIfPresent(String.self, forKey: .swiftState) ?? "absent"
        pendingRecordings = try c.decodeIfPresent([PendingRecording].self, forKey: .pendingRecordings) ?? []
    }

    /// What the next launch (or Retry) does with this answer. Pure: the
    /// driver acts on it and reads the status again.
    package enum Next: Equatable, Sendable {
        case nothing
        case adoptState
        case handOverKeys
        case deleteDesktopKeys
        case finished
    }

    package var next: Next {
        switch identity {
        case "confirmed": return .finished
        case "adopted": return .deleteDesktopKeys // a missing confirm: delete again, then confirm
        default: break
        }
        if step == "done" { return .handOverKeys }
        if !step.isEmpty || swiftState == "present" { return .adoptState }
        return .nothing // absent, or ignored (a later MobileHub: never imported, no Retry)
    }
}

/// `hub adopt --settings-stdin --json`: the step reached and the error class.
package struct HubAdoptRunAnswer: Decodable, Equatable, Sendable {
    package let step: String
    package let error: String

    enum CodingKeys: String, CodingKey { case step, error }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = try c.decodeIfPresent(String.self, forKey: .step) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

/// `hub adopt --keys-stdin|--confirm-deleted --json`: adopted|confirmed, or
/// the error class.
package struct HubAdoptIdentityAnswer: Decodable, Equatable, Sendable {
    package let identity: String
}

/// The owner's settings `hub adopt --settings-stdin` takes on stdin.
package struct HubAdoptSettings: Encodable, Equatable, Sendable {
    package let enabled: Bool
    package let startSessionAllows: [String: Bool]

    package init(enabled: Bool, startSessionAllows: [String: Bool]) {
        self.enabled = enabled
        self.startSessionAllows = startSessionAllows
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case startSessionAllows = "start_session_allows"
    }
}
