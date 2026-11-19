import Foundation

/// The owner's one "yes" before Watchtower runs AI on its own (#1886, spec
/// §3). Background = started by a timer, a sync cycle or an event; not by the
/// owner's own gesture. The Swift twin of Go's `aiconsent.Resolve`, pinned to
/// it by the shared fixture `internal/aiconsent/testdata/consent_cases.json`
/// (BGAI-03).
package enum BackgroundAIConsent {
    /// The automation run triggers that are background work (spec §2.2): the
    /// twin of Go's `aiconsent.BackgroundTrigger`. Every other trigger
    /// (`manual`, `button`, `dry_run`, `reply`) is the owner's gesture.
    package static let backgroundRunTriggers: Set<String> = ["schedule", "catch_up", "event", "sync"]

    /// The env a process that serves admitted background unit `unit` passes
    /// to its children (Go `aiconsent.ChildEnv` of an admitted ctx).
    package static func admittedEnvironment(unit: String) -> [String] {
        ["\(CLIOrigin.environmentKey)=background", "\(admittedEnvironmentKey)=\(unit)"]
    }

    /// Go's `aiconsent.EnvAdmitted`.
    package static let admittedEnvironmentKey = "WATCHTOWER_AI_ADMITTED"

    package enum Effective: String, Sendable {
        case allowed, paused
    }

    package enum Reason: String, Sendable {
        case unanswered, owner, organization
    }

    package struct State: Equatable, Sendable {
        package let effective: Effective
        package let reason: Reason
        /// The consent screen is due (onboarding step or upgrade sheet).
        package let prompt: Bool
        /// The organization decided: the Settings switch is locked.
        package let locked: Bool

        package var isAllowed: Bool { effective == .allowed }

        package static let allowedByOwner = Self(effective: .allowed, reason: .owner, prompt: false, locked: false)
    }

    /// Spec §3.2's table. `answer` is the raw `ai.background_runs`; any value
    /// other than `allowed` or `paused` reads as not answered. `policy` is the
    /// forced `AllowBackgroundAI` (a wrong type already reads `false`).
    package static func resolve(answer: String?, policy: Bool?) -> State { // swiftlint:disable:this discouraged_optional_boolean
        switch (answer, policy) {
        case (_, false?):
            State(effective: .paused, reason: .organization, prompt: false, locked: true)
        case ("allowed"?, _):
            .allowedByOwner
        case ("paused"?, _):
            State(effective: .paused, reason: .owner, prompt: false, locked: false)
        case (_, true?):
            State(effective: .allowed, reason: .organization, prompt: false, locked: false)
        default:
            State(effective: .paused, reason: .unanswered, prompt: true, locked: false)
        }
    }

    /// The state from a read of config.yaml, as Go's `aiconsent.Current`: a
    /// file that exists but cannot be read or parsed (`readFailed`) leaves the
    /// owner's answer unknown, so it reads paused whatever the profile says
    /// (a permissive profile stands in only for an owner who has not
    /// answered). A missing file is a clean read with no answer.
    package static func resolve(answer: String?, readFailed: Bool, policy: Bool?) -> State { // swiftlint:disable:this discouraged_optional_boolean
        guard readFailed else { return resolve(answer: answer, policy: policy) }
        let state = resolve(answer: nil, policy: policy)
        return state.isAllowed ? resolve(answer: nil, policy: nil) : state
    }
}
