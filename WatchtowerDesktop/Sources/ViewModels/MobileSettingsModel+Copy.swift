import Foundation

/// Every line Settings → Mobile and its pairing sheet show (go hub plan 3
/// Task 23, mockups `docs/design/mockups/go-hub/index.html` §1–§13, copy
/// accepted in ask #906). The views hold no string literal; the model tests
/// pin these.
extension MobileSettingsModel {
    // MARK: Sections and rows

    nonisolated static let sectionTitle = "Mobile"
    nonisolated static let phonesTitle = "Phones"
    nonisolated static let recordingsSectionTitle = "Recordings"
    nonisolated static let loadingText = "Loading…"
    nonisolated static let retryTitle = "Retry"
    nonisolated static let emptyText = "No phones linked"
    nonisolated static let emptyDetail = "Link one to see this Mac's board and sessions on your phone."
    nonisolated static let linkTitle = "Link a phone…"
    nonisolated static let toggleTitle = "Mobile sync"
    nonisolated static let toggleOnCaption = "This Mac shares its board and sessions with your linked phones."
    nonisolated static let toggleOffCaption = "Off. Linked phones are kept."
    /// A Go hub ran first and a Swift hub's state appeared beside it (ask #949): off, no action here.
    nonisolated static let swiftBesideGoTitle = "Mobile is off"
    nonisolated static let swiftBesideGoDetail = "This Mac has phone data from two Watchtower setups. "
        + "Remove one of them to turn Mobile back on."
    nonisolated static let policyTitle = "Mobile is turned off by your organization"
    nonisolated static let policyDetail = "Managed by your organization. Linked phones are kept and work again when it is allowed."
    nonisolated static let macNameTitle = "Mac name"
    nonisolated static let macNameCaption = "Shown on the phone"
    nonisolated static let renameTitle = "Rename this Mac"
    nonisolated static let renamePrompt = "Name"
    nonisolated static let saveTitle = "Save"
    nonisolated static let cancelTitle = "Cancel"
    nonisolated static let recordingsTitle = "Transcribe phone recordings on this Mac"
    nonisolated static let recordingsCaption = "Recordings from a phone are transcribed here."
    nonisolated static let turningOn = "Turning on…"
    nonisolated static let turningOff = "Turning off…"
    nonisolated static let saving = "Saving…"
    nonisolated static let transportTitle = "Transport"
    nonisolated static let keepAwakeTitle = "Keep this Mac awake for the iPhone"
    nonisolated static let keepAwakeCaption = "While a session runs and your iPhone has been in touch in the last 24 hours, "
        + "this Mac does not go to sleep on its own. A closed lid on battery still sleeps it."
    nonisolated static let corpNotice = "Work data from this Mac will be stored in your personal iCloud account."
    nonisolated static let needsSignedBuild = "Needs a signed build"
    nonisolated static let slowingLine = "iCloud is slowing sync down"
    /// Throttling this long shows `slowingLine` (spec §9).
    nonisolated static let slowingAfter: TimeInterval = 60

    /// The sentence for an iCloud account the Mac can't use (today's
    /// `MobileLinkError.account` copy); nil when it is fine or unknown, and
    /// for a missing entitlement, which `needsSignedBuild` says.
    nonisolated static func accountLine(_ account: String) -> String? {
        switch account {
        case "no_account": "Mobile isn't available on this Mac: iCloud is off."
        case "restricted": "Mobile isn't available on this Mac: iCloud is restricted by your organization."
        case "temporarily_unavailable": "Mobile isn't available on this Mac: iCloud account temporarily unavailable"
        default: nil
        }
    }
    nonisolated static let removeTitle = "Remove…"
    nonisolated static let removeConfirmTitle = "Remove"
    nonisolated static let allowTitle = "Allow…"
    nonisolated static let allowConfirmTitle = "Allow"
    nonisolated static let revokeTitle = "Revoke"
    nonisolated static let thisPhone = "this phone"

    nonisolated static func loadFailed(_ why: String) -> String { "Couldn't read Mobile's state. \(why)" }

    // MARK: Hub off

    /// The off row for `hub status`'s reason: its title and caption, whether
    /// the owner's toggle shows (not under a policy) and whether it is on.
    struct OffCopy: Equatable {
        let title: String
        let detail: String?
        let showsToggle: Bool
        let toggleOn: Bool
        let managed: Bool
    }

    nonisolated static func offCopy(_ reason: String) -> OffCopy {
        func on(_ detail: String) -> OffCopy {
            OffCopy(title: toggleTitle, detail: detail, showsToggle: true, toggleOn: true, managed: false)
        }
        switch reason {
        case "disabled":
            return OffCopy(title: toggleTitle, detail: toggleOffCaption, showsToggle: true, toggleOn: false, managed: false)
        case "policy_off":
            return OffCopy(title: policyTitle, detail: policyDetail, showsToggle: false, toggleOn: false, managed: true)
        case "awaiting_adoption":
            return on("Waiting for Mobile to move to the new version.")
        case "adoption_failed":
            return on("Mobile could not move to the new version. It stays off until it has moved.")
        case "session_host_v1":
            return on("Waiting for running sessions to restart once with this update.")
        case "swift_beside_go":
            return OffCopy(title: swiftBesideGoTitle, detail: swiftBesideGoDetail, showsToggle: false, toggleOn: false, managed: false)
        case "":
            return on("Mobile is not running. It starts with the next sync.")
        default:
            return on((reasonLine(reason) ?? HubLine(text: unknownReason, tone: .warning)).text)
        }
    }

    /// A line's weight: neutral (secondary), warning or error (red, as
    /// today's "Mobile couldn't start").
    enum LineTone: Equatable { case neutral, warning, error }

    struct HubLine: Equatable {
        let text: String
        let tone: LineTone
    }

    /// The owner's sentence for a status reason; never the raw identifier
    /// (an unknown one reads `unknownReason`). nil for "" (no reason).
    nonisolated static func reasonLine(_ reason: String) -> HubLine? {
        func warning(_ text: String) -> HubLine { HubLine(text: text, tone: .warning) }
        func error(_ text: String) -> HubLine { HubLine(text: text, tone: .error) }
        switch reason {
        case "": return nil
        case "start_failed": return error("Mobile couldn't start. It tries again in a moment.")
        case "sidecar_unreadable": return error("Mobile couldn't start: its data on this Mac can't be read.")
        case "run_dir_unusable": return error("Mobile couldn't start: its folder on this Mac can't be used.")
        case "bridge_unavailable": return error("Mobile can't run: this build can't use iCloud and has no Relay set up.")
        case "locked": return warning("Another Watchtower process runs Mobile on this Mac.")
        case "relay_unreachable": return warning("Relay can't be reached right now. Phones on Relay wait.")
        case "not_vouched": return warning("Relay is waiting for a linked phone to vouch for this Mac.")
        case "not_admitted": return warning("Relay hasn't admitted this Mac yet: a phone with a Relay subscription has to link it.")
        case "vouch_revoked": return warning("The phone that vouched for this Mac on Relay took it back. Link a phone with Relay again.")
        case "needs_relay": return warning("This hub needs Relay to link phones.")
        case "no_relay_origin": return warning("Relay is not set up on this Mac: phones link over iCloud only.")
        case "not_test_workspace": return warning("Mobile runs only in its test workspace on this Mac.")
        default: return warning(unknownReason)
        }
    }

    nonisolated static let unknownReason = "Mobile reports a problem this version can't name. It tries again by itself."

    /// A running or starting hub's line: its reason's sentence, else
    /// "Starting…" / "Paused…"; nil when it just runs.
    nonisolated static func hubLine(state: String, reason: String?) -> HubLine? {
        if let line = reasonLine(reason ?? "") { return line }
        switch state {
        case "starting": return HubLine(text: "Starting…", tone: .neutral)
        case "paused": return HubLine(text: "Paused. It goes on by itself.", tone: .neutral)
        default: return nil
        }
    }

    /// The owner's off deleting what the hub published (`off_delete`):
    /// today's off-delete lines; nil when it is done.
    nonisolated static func offDeleteLine(_ state: String?) -> String? {
        switch state {
        case "pending": "Deleting what this Mac synced to iCloud…"
        case "failed": "This Mac's synced data was only partly deleted. That finishes while Mobile stays off."
        default: nil
        }
    }

    // MARK: Transport

    /// A phone's or the hub's transport as the owner reads it.
    nonisolated static func transportLabel(_ transport: String) -> String {
        switch transport {
        case "cloudkit": "iCloud"
        case "relay": "Relay"
        case "pending": "Waiting for Relay"
        default: transport
        }
    }

    /// When the last switch happened: "today 10:42", "yesterday 10:42", else "12 Oct 10:42".
    nonisolated static func whenText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }

    /// Who switched: a phone's name (a phone no longer linked has none), or the subscription that ended.
    nonisolated static func switchedByText(_ by: String, names: [String: String]) -> String {
        by == "entitlement_expired" ? "when the Relay subscription ended" : "by \(names[by.uppercased()] ?? removedPhone)"
    }

    nonisolated static let removedPhone = "a phone no longer linked"

    /// The hub's Transport row: "Switched to Relay by Phone A · today 10:42".
    nonisolated static func hubSwitchedLine(to transport: String, by: String, at: Date, now: Date, names: [String: String]) -> String {
        "Switched to \(transportLabel(transport)) \(switchedByText(by, names: names)) · \(whenText(at, now: now))"
    }

    /// A phone's line on the hub's current transport: "switched by Phone A today 10:42".
    nonisolated static func phoneSwitchedLine(by: String, at: Date, now: Date, names: [String: String]) -> String {
        "switched \(switchedByText(by, names: names)) \(whenText(at, now: now))"
    }

    /// The phone's Apple ID scope, as today's row says it.
    nonisolated static func scopeLabel(_ scope: String) -> String? {
        switch scope {
        case "private": "Same Apple ID"
        case "shared": "Shared"
        default: nil
        }
    }

    nonisolated static func linkedText(_ date: Date) -> String {
        "Linked \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    // MARK: Grants (today's copy, mobile POC spec §10, #517, #565)

    nonisolated static func allowQuestion(name: String) -> String {
        "Allow \"\(name)\" to type into Claude Code sessions?"
    }

    nonisolated static func permissionsQuestion(name: String) -> String {
        "Allow \"\(name)\" to approve commands in Claude Code sessions?"
    }

    nonisolated static func startSessionsQuestion(name: String) -> String {
        "Allow \"\(name)\" to start Claude Code sessions on this Mac?"
    }

    nonisolated static let startSessionsMessage = "The phone can then start a session on a board target, and the agent reads "
        + "that target's text. Revoke turns it off again."
    nonisolated static let permissionsMessage = "The phone can then allow or deny a Claude Code permission prompt, one call "
        + "at a time. Revoke turns it off again."

    nonisolated static func allowMessage(_ phone: PhoneRow?) -> String {
        let base = "The phone can then send text to sessions running on this Mac. Revoke turns it off again."
        guard phone?.startSessionsGranted == true else { return base }
        return base + " Starting sessions, allowed earlier for this phone, comes back with it."
    }

    nonisolated static func typingLabel(_ phone: PhoneRow) -> String {
        if phone.typing { return "Typing allowed" }
        return phone.typingRequested ? "Asks to type into sessions" : "Typing off"
    }

    nonisolated static func startSessionsLabel(_ phone: PhoneRow) -> String {
        if !phone.typing { return "Starting sessions needs typing" }
        if !phone.startSessionsGranted { return "Starting sessions off" }
        return phone.startSessions ? "Starting sessions allowed" : "Starting sessions allowed on the Mac — off on the phone"
    }

    nonisolated static func permissionsLabel(_ phone: PhoneRow) -> String {
        if phone.permissions { return "Permission prompts allowed" }
        return phone.permissionsRequested ? "Asks to answer permission prompts" : "Permission prompts off"
    }

    nonisolated static func couldNotChange(_ grant: String, name: String, why: String) -> String {
        let what = switch grant {
        case "typing": "typing"
        case "permissions": "permission prompts"
        default: "starting sessions"
        }
        return "Couldn't change \(what) for \(name). \(why)"
    }

    // MARK: Remove

    nonisolated static func removeQuestion(name: String) -> String { "Remove \"\(name)\"?" }

    /// What Remove does: a shared phone loses the Mac's data at once; a
    /// same-Apple-ID one keeps what it synced but reads nothing new (D9).
    nonisolated static func removeConsequence(scope: String) -> String {
        scope == "private"
            ? "It stops syncing with this Mac and can no longer read anything new: this Mac changes its keys. "
                + "Linking it again needs a new code."
            : "It leaves this Mac at once and loses its data. Linking it again needs a new code."
    }

    nonisolated static func removed(_ phone: PhoneRow) -> String {
        phone.scope == "private"
            ? "Removed \(phone.name). It can no longer read anything new from this Mac."
            : "Removed \(phone.name)."
    }

    nonisolated static func couldNotRemove(_ name: String, why: String) -> String { "Couldn't remove \(name). \(why)" }
    nonisolated static func couldNotRename(_ why: String) -> String { "Couldn't rename this Mac. \(why)" }
    nonisolated static func couldNotSwitch(_ on: Bool, why: String) -> String {
        "Couldn't turn Mobile \(on ? "on" : "off"). \(why)"
    }

    // MARK: Recordings

    nonisolated static let noTranscriber = "This host has no transcriber."

    nonisolated static func keptLine(_ kept: KeptRecordings) -> String {
        kept.count == 1
            ? "1 phone recording was not transcribed during the update"
            : "\(kept.count) phone recordings were not transcribed during the update"
    }

    nonisolated static func keptRemovalLine(_ kept: KeptRecordings) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Removed from this Mac on \(formatter.string(from: kept.removeAt))"
    }

    nonisolated static let showInFinderTitle = "Show in Finder"
    nonisolated static let discardTitle = "Discard…"
    nonisolated static let discardConfirmTitle = "Discard"
    nonisolated static let discardQuestion = "Discard this phone recording?"
    nonisolated static let discardMessage = "Its audio is deleted from this Mac. This can't be undone."
    nonisolated static let failedRecordingCaption = "Its audio is kept on this Mac for 31 days."

    /// A failed phone recording's line, by the class Desktop failed it with
    /// (Task 17's `PhoneRecordingQueue.FailureClass`, a Go↔Swift dual path).
    nonisolated static func failedRecordingLine(_ failure: PhoneRecordingQueue.FailureClass) -> String {
        switch failure {
        case .noSpeech: "A phone recording had no speech in it"
        case .notAudio: "A phone recording is not audio this Mac can read"
        case .missingAudio: "A phone recording's audio is missing"
        case .transcriptionFailed, .unreadable, .ingestFailed: "A phone recording could not be transcribed"
        }
    }

    nonisolated static func couldNotRetry(_ why: String) -> String { "Couldn't transcribe the recording again. \(why)" }
    nonisolated static func couldNotDiscard(_ why: String) -> String { "Couldn't discard the recording. \(why)" }
}
