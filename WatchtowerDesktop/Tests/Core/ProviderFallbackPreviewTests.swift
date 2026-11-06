import XCTest
@testable import WatchtowerCore

final class ProviderFallbackPreviewTests: XCTestCase {
    func testEveryStateHasCopyAndAnExplicitActionPolicyInBothDirections() {
        let actions: [ProviderFallbackPreview.State: String] = [
            .connectionError: "Retry", .connectionNetworkError: "Retry", .notInstalled: "Open setup",
            .notVerified: "Test connection", .ready: "Save", .applyError: "Retry",
            .bothLimited: "Check again", .stopped: "Review actions", .pinned: "Change provider choice"
        ]
        for provider in ProviderFallbackPreview.Provider.allCases {
            for state in ProviderFallbackPreview.State.allCases {
                let preview = ProviderFallbackPreview(preferred: provider, state: state)
                XCTAssertFalse(preview.copy.title.isEmpty, state.rawValue)
                XCTAssertFalse(preview.copy.detail.isEmpty, state.rawValue)
                let expected = state == .empty ? "Connect \(provider.other.rawValue)"
                    : state == .recovered ? "Use \(provider.rawValue)" : actions[state]
                XCTAssertEqual(preview.copy.action, expected, state.rawValue)
            }
        }
    }

    func testPolicyAndMissingCapabilitiesDoNotOfferRetryOrClaimFallback() {
        for provider in ProviderFallbackPreview.Provider.allCases {
            let policy = ProviderFallbackPreview(preferred: provider, state: .policy)
            XCTAssertTrue(policy.copy.title.contains(provider.rawValue))
            XCTAssertTrue(policy.copy.detail.contains("No provider was started"))
            XCTAssertNil(policy.copy.action)
            let unsupported = ProviderFallbackPreview(preferred: provider, state: .unsupported)
            XCTAssertTrue(unsupported.isChat)
            XCTAssertEqual(unsupported.actualProvider, provider.rawValue)
            XCTAssertTrue(unsupported.copy.detail.contains("required attachment or tool"))
            XCTAssertNil(unsupported.copy.action)
        }
    }

    func testReverseDirectionNamesTheActualReserve() {
        for preferred in ProviderFallbackPreview.Provider.allCases {
            let preview = ProviderFallbackPreview(preferred: preferred, state: .fallback)
            XCTAssertEqual(preview.actualProvider, preferred.other.rawValue)
            XCTAssertEqual(preview.copy.title, "Using \(preferred.other.rawValue)")
            XCTAssertTrue(preview.copy.detail.contains("\(preferred.rawValue) reached its limit"))
        }
    }

    func testRecoveryDoesNotPromiseToSwitchTheCurrentChat() {
        let preview = ProviderFallbackPreview(preferred: .codex, state: .recovered)
        XCTAssertTrue(preview.isChat)
        XCTAssertEqual(preview.actualProvider, "Claude")
        XCTAssertEqual(preview.copy.action, "Use Codex")
        XCTAssertTrue(preview.copy.detail.contains("This chat stays with Claude until you switch"))
    }

    func testBusyStatesCannotOfferASecondAttempt() {
        for state in [ProviderFallbackPreview.State.checking, .applying, .probing] {
            let copy = ProviderFallbackPreview(preferred: .claude, state: state).copy
            XCTAssertTrue(copy.busy)
            XCTAssertNil(copy.action)
        }
    }

    func testConnectionAndApplyErrorsHaveDistinctRecovery() {
        let connection = ProviderFallbackPreview(preferred: .claude, state: .connectionError)
        let apply = ProviderFallbackPreview(preferred: .claude, state: .applyError)
        XCTAssertFalse(connection.enabled)
        XCTAssertEqual(connection.copy.action, "Retry")
        XCTAssertTrue(apply.enabled)
        XCTAssertEqual(apply.copy.action, "Retry")
        XCTAssertTrue(apply.copy.detail.contains("not confirmed"))
        let unknown = ProviderFallbackPreview(preferred: .codex, state: .notVerified)
        XCTAssertFalse(unknown.enabled)
        XCTAssertTrue(unknown.copy.detail.contains("sends a short AI request"))
        let network = ProviderFallbackPreview(preferred: .claude, state: .connectionNetworkError)
        XCTAssertTrue(network.copy.detail.contains("sign-in has not been changed"))
    }

    func testEffectsAndPinsNeverOfferBlindRetry() {
        let stopped = ProviderFallbackPreview(preferred: .claude, state: .stopped)
        XCTAssertEqual(stopped.copy.action, "Review actions")
        XCTAssertTrue(stopped.copy.detail.contains("Nothing will be repeated automatically"))
        let pinned = ProviderFallbackPreview(preferred: .codex, state: .pinned)
        XCTAssertEqual(pinned.actualProvider, "Codex")
        XCTAssertTrue(pinned.chatPolicyValue.contains("Only Codex"))
        XCTAssertTrue(pinned.copy.detail.contains("use Auto model"))
    }

    func testWaitingDoesNotPromiseReplayOfAutomationRecipes() {
        let copy = ProviderFallbackPreview(preferred: .claude, state: .bothLimited).copy
        XCTAssertTrue(copy.detail.contains("Unprocessed source data is kept; syncing continues"))
        XCTAssertFalse(copy.detail.contains("all jobs"))
        XCTAssertEqual(copy.action, "Check again")
    }
}
