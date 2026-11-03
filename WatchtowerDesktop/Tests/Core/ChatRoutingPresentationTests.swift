import XCTest
@testable import WatchtowerCore

final class ChatRoutingPresentationTests: XCTestCase {
    func testRecoveryUsesRealLocalHealthAndStaysStickyInBothDirections() throws {
        for preferred in ProviderFallbackPreview.Provider.allCases {
            let p = preferred.rawValue.lowercased(), reserve = preferred.other.rawValue.lowercased()
            let data = Data("""
                {"preferred_provider":"\(p)","enabled":true,"revision":"fake-revision","providers":[
                  {"provider":"\(p)","state":"available"},{"provider":"\(reserve)","state":"available"}]}
                """.utf8)
            let health = try ChatRoutingStatus.parse(data)
            let view = ChatRoutingPresentation(preferred: preferred, automatic: true, actualProvider: reserve,
                                               actualModel: "actual-model", reason: "quota_exhausted", health: health, busy: false)
            XCTAssertEqual(view.preview?.state, .recovered)
            XCTAssertEqual(view.actual, "Current provider: \(preferred.other.rawValue) · actual-model")
            XCTAssertEqual(view.preview?.copy.action, "Use \(preferred.rawValue)")
            XCTAssertTrue(view.canUsePreferred)
            let busy = ChatRoutingPresentation(preferred: preferred, automatic: true, actualProvider: reserve,
                                               actualModel: "actual-model", reason: nil, health: health, busy: true)
            XCTAssertFalse(busy.canUsePreferred)
            let unknown = ChatRoutingPresentation(preferred: preferred, automatic: true, actualProvider: reserve,
                                                  actualModel: nil, reason: nil, health: nil, busy: false)
            XCTAssertEqual(unknown.preview?.state, .fallback)
            XCTAssertFalse(unknown.preview?.copy.detail.contains("14:30") ?? true)
        }
    }

    func testPassedResetDoesNotClaimRecoveryOrInventAnActualProvider() throws {
        let health = try ChatRoutingStatus.parse(Data("""
            {"preferred_provider":"claude","enabled":true,"revision":"r","providers":[
            {"provider":"claude","state":"quota_wait","next_probe_at":"2020-01-01T00:00:00.123456789Z"}]}
            """.utf8))
        let view = ChatRoutingPresentation(preferred: .claude, automatic: true, actualProvider: "codex",
                                           actualModel: "real-codex-model", reason: nil, health: health, busy: false)
        XCTAssertEqual(view.preview?.state, .fallback)
        XCTAssertFalse(view.canUsePreferred)
        let fresh = ChatRoutingPresentation(preferred: .claude, automatic: true, actualProvider: nil,
                                            actualModel: nil, reason: nil, health: health, busy: false)
        XCTAssertNil(fresh.actual)
        XCTAssertNil(fresh.preview)
    }
}
