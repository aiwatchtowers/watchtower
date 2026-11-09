import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

final class ProviderFallbackPreviewTests: XCTestCase {
    func testEveryStateHasCopyAndAnExplicitActionPolicyInBothDirections() {
        let actions: [ProviderFallbackPreview.State: String] = [
            .connectionError: "Retry", .connectionNetworkError: "Retry", .notInstalled: "Open setup",
            .notVerified: "Test connection", .ready: "Save", .applyError: "Retry",
            .bothLimited: "Check again", .stopped: "Review actions", .pinned: "Change provider choice"
        ]
        for pair in ProviderFallbackPreview.Pair.fixturePairs {
            for state in ProviderFallbackPreview.State.allCases {
                let preview = ProviderFallbackPreview(pair: pair, state: state)
                XCTAssertFalse(preview.copy.title.isEmpty, state.rawValue)
                XCTAssertFalse(preview.copy.detail.isEmpty, state.rawValue)
                let expected = state == .empty ? "Connect \(pair.reserve.name)"
                    : state == .recovered ? "Use \(pair.preferred.name)" : actions[state]
                XCTAssertEqual(preview.copy.action, expected, state.rawValue)
            }
        }
    }

    func testPolicyAndMissingCapabilitiesDoNotOfferRetryOrClaimFallback() {
        for pair in ProviderFallbackPreview.Pair.fixturePairs {
            let policy = ProviderFallbackPreview(pair: pair, state: .policy)
            XCTAssertTrue(policy.copy.title.contains(pair.preferred.name))
            XCTAssertTrue(policy.copy.detail.contains("No provider was started"))
            XCTAssertNil(policy.copy.action)
            let unsupported = ProviderFallbackPreview(pair: pair, state: .unsupported)
            XCTAssertTrue(unsupported.isChat)
            XCTAssertEqual(unsupported.actualProvider, pair.preferred.name)
            XCTAssertTrue(unsupported.copy.detail.contains("required attachment or tool"))
            XCTAssertNil(unsupported.copy.action)
        }
    }

    func testReverseDirectionNamesTheActualReserve() {
        for pair in ProviderFallbackPreview.Pair.fixturePairs {
            let preview = ProviderFallbackPreview(pair: pair, state: .fallback)
            XCTAssertEqual(preview.actualProvider, pair.reserve.name)
            XCTAssertEqual(preview.copy.title, "Using \(pair.reserve.name)")
            XCTAssertTrue(preview.copy.detail.contains("\(pair.preferred.name) reached its limit"))
        }
    }

    func testRecoveryDoesNotPromiseToSwitchTheCurrentChat() {
        let preview = ProviderFallbackPreview(pair: .codexFirst, state: .recovered)
        XCTAssertTrue(preview.isChat)
        XCTAssertEqual(preview.actualProvider, "Claude")
        XCTAssertEqual(preview.copy.action, "Use Codex")
        XCTAssertTrue(preview.copy.detail.contains("This chat stays with Claude until you switch"))
        XCTAssertEqual(preview.copy.title, "Codex can be tried")
        XCTAssertTrue(preview.copy.detail.contains("No local quota block is currently recorded for Codex"))
        XCTAssertFalse(preview.copy.detail.contains("Background tasks have returned"))
    }

    func testBusyStatesCannotOfferASecondAttempt() {
        for state in [ProviderFallbackPreview.State.checking, .applying, .probing] {
            let copy = ProviderFallbackPreview(pair: .claudeFirst, state: state).copy
            XCTAssertTrue(copy.busy)
            XCTAssertNil(copy.action)
        }
    }

    func testConnectionAndApplyErrorsHaveDistinctRecovery() {
        let connection = ProviderFallbackPreview(pair: .claudeFirst, state: .connectionError)
        let apply = ProviderFallbackPreview(pair: .claudeFirst, state: .applyError)
        XCTAssertFalse(connection.enabled)
        XCTAssertEqual(connection.copy.action, "Retry")
        XCTAssertTrue(apply.enabled)
        XCTAssertEqual(apply.copy.action, "Retry")
        XCTAssertTrue(apply.copy.detail.contains("not confirmed"))
        let unknown = ProviderFallbackPreview(pair: .codexFirst, state: .notVerified)
        XCTAssertFalse(unknown.enabled)
        XCTAssertTrue(unknown.copy.detail.contains("sends a short AI request"))
        let network = ProviderFallbackPreview(pair: .claudeFirst, state: .connectionNetworkError)
        XCTAssertTrue(network.copy.detail.contains("sign-in has not been changed"))
    }

    func testEffectsAndPinsNeverOfferBlindRetry() {
        let stopped = ProviderFallbackPreview(pair: .claudeFirst, state: .stopped)
        XCTAssertEqual(stopped.copy.action, "Review actions")
        XCTAssertTrue(stopped.copy.detail.contains("Nothing will be repeated automatically"))
        let pinned = ProviderFallbackPreview(pair: .codexFirst, state: .pinned)
        XCTAssertEqual(pinned.actualProvider, "Codex")
        XCTAssertTrue(pinned.chatPolicyValue.contains("Only Codex"))
        XCTAssertTrue(pinned.copy.detail.contains("use Auto model"))
    }

    func testWaitingDoesNotPromiseReplayOfAutomationRecipes() {
        let copy = ProviderFallbackPreview(pair: .claudeFirst, state: .bothLimited).copy
        XCTAssertTrue(copy.detail.contains("Unprocessed source data is kept; syncing continues"))
        XCTAssertFalse(copy.detail.contains("all jobs"))
        XCTAssertEqual(copy.action, "Check again")
    }
}
