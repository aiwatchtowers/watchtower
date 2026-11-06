import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

final class ChatRoutingPresentationTests: XCTestCase {
    func testRecoveryUsesRealLocalHealthAndStaysStickyInBothDirections() throws {
        for pair in ProviderFallbackPreview.Pair.fixturePairs {
            let p = pair.preferred.id, reserve = pair.reserve.id
            let data = Data("""
                {"preferred_provider":"\(p)","enabled":true,"revision":"fake-revision","providers":[
                  {"provider":"\(p)","state":"available"},{"provider":"\(reserve)","state":"available"}]}
                """.utf8)
            let health = try ChatRoutingStatus.parse(data)
            let view = ChatRoutingPresentation(pair: pair, automatic: true, actualProvider: reserve,
                                               actualModel: "actual-model", reason: "quota_exhausted", health: health, busy: false)
            XCTAssertEqual(view.preview?.state, .recovered)
            XCTAssertEqual(view.actual, "Current provider: \(pair.reserve.name) · actual-model")
            XCTAssertEqual(view.preview?.copy.action, "Use \(pair.preferred.name)")
            XCTAssertTrue(view.canUsePreferred)
            let busy = ChatRoutingPresentation(pair: pair, automatic: true, actualProvider: reserve,
                                               actualModel: "actual-model", reason: "quota_exhausted", health: health, busy: true)
            XCTAssertFalse(busy.canUsePreferred)
            let unknown = ChatRoutingPresentation(pair: pair, automatic: true, actualProvider: reserve,
                                                  actualModel: nil, reason: nil, health: nil, busy: false)
            XCTAssertNil(unknown.preview)
            XCTAssertFalse(unknown.canUsePreferred)
        }
    }

    func testPassedResetDoesNotClaimRecoveryOrInventAnActualProvider() throws {
        let health = try ChatRoutingStatus.parse(Data("""
            {"preferred_provider":"claude","enabled":true,"revision":"r","providers":[
            {"provider":"claude","state":"quota_wait","next_probe_at":"2020-01-01T00:00:00.123456789Z"}]}
            """.utf8))
        let view = ChatRoutingPresentation(pair: .claudeFirst, automatic: true, actualProvider: "codex",
                                           actualModel: "real-codex-model", reason: "quota_exhausted", health: health, busy: false)
        XCTAssertEqual(view.preview?.state, .fallback)
        XCTAssertFalse(view.canUsePreferred)
        let fresh = ChatRoutingPresentation(pair: .claudeFirst, automatic: true, actualProvider: nil,
                                            actualModel: nil, reason: nil, health: health, busy: false)
        XCTAssertNil(fresh.actual)
        XCTAssertNil(fresh.preview)
    }
}

extension ChatRoutingPresentationTests {
    func testHistoricalActualAndChangedPreferenceDoNotInventQuotaOrRecovery() throws {
        for pair in ProviderFallbackPreview.Pair.fixturePairs {
            let health = try ChatRoutingStatus.parse(Data("""
                {"preferred_provider":"\(pair.preferred.id)","enabled":true,"revision":"new-revision",
                 "providers":[{"provider":"\(pair.preferred.id)","state":"available"}]}
                """.utf8))
            for reason in [nil, "", "preferred", "fallback_disabled", "unrecognized"] as [String?] {
                for status in [nil, health] as [ChatRoutingStatus?] {
                    let view = ChatRoutingPresentation(pair: pair, automatic: true,
                                                       actualProvider: pair.reserve.id,
                                                       actualModel: "historical-model", reason: reason, health: status, busy: false)
                    XCTAssertNil(view.preview, "provider inequality is not quota evidence: \(reason ?? "nil")")
                    XCTAssertFalse(view.canUsePreferred)
                    XCTAssertEqual(view.actual, "Current provider: \(pair.reserve.name) · historical-model")
                }
            }
        }
    }
}
