import XCTest
@testable import WatchtowerCore

final class ChatRoutingPresentationTests: XCTestCase {
    func testLocalAvailabilityOffersManualChoiceAndStaysStickyInBothDirections() throws {
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
                                               actualModel: "actual-model", reason: "quota_exhausted", health: health, busy: true)
            XCTAssertFalse(busy.canUsePreferred)
            let unknown = ChatRoutingPresentation(preferred: preferred, automatic: true, actualProvider: reserve,
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
        let view = ChatRoutingPresentation(preferred: .claude, automatic: true, actualProvider: "codex",
                                           actualModel: "real-codex-model", reason: "quota_exhausted", health: health, busy: false)
        XCTAssertEqual(view.preview?.state, .fallback)
        XCTAssertFalse(view.canUsePreferred)
        let fresh = ChatRoutingPresentation(preferred: .claude, automatic: true, actualProvider: nil,
                                            actualModel: nil, reason: nil, health: health, busy: false)
        XCTAssertNil(fresh.actual)
        XCTAssertNil(fresh.preview)
    }
}

extension ChatRoutingPresentationTests {
    func testHistoricalActualAndChangedPreferenceDoNotInventQuotaOrRecovery() throws {
        for preferred in ProviderFallbackPreview.Provider.allCases {
            let health = try ChatRoutingStatus.parse(Data("""
                {"preferred_provider":"\(preferred.rawValue.lowercased())","enabled":true,"revision":"new-revision",
                 "providers":[{"provider":"\(preferred.rawValue.lowercased())","state":"available"}]}
                """.utf8))
            for reason in [nil, "", "preferred", "fallback_disabled", "unrecognized"] as [String?] {
                for status in [nil, health] as [ChatRoutingStatus?] {
                    let view = ChatRoutingPresentation(preferred: preferred, automatic: true,
                                                       actualProvider: preferred.other.rawValue.lowercased(),
                                                       actualModel: "historical-model", reason: reason, health: status, busy: false)
                    XCTAssertNil(view.preview, "provider inequality is not quota evidence: \(reason ?? "nil")")
                    XCTAssertFalse(view.canUsePreferred)
                    XCTAssertEqual(view.actual, "Current provider: \(preferred.other.rawValue) · historical-model")
                }
            }
        }
    }
}

extension ChatRoutingPresentationTests {
    /// The Go actual-command test verifies this same wire fixture against a
    /// fresh owned HOME with forbidden provider executables and zero requests.
    func testFreshCommandDTOOffersManualChoiceWithoutInventingCompletedWork() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("cmd/testdata/routing/fresh_status.json"))
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let statuses = try XCTUnwrap(rows)
        XCTAssertEqual(statuses.count, ProviderFallbackPreview.Provider.allCases.count)
        for row in statuses {
            let health = try ChatRoutingStatus.parse(JSONSerialization.data(withJSONObject: row))
            let preferred = try XCTUnwrap(ProviderFallbackPreview.Provider.allCases.first {
                $0.rawValue.lowercased() == health.preferredProvider
            })
            let view = ChatRoutingPresentation(preferred: preferred, automatic: true,
                                               actualProvider: preferred.other.rawValue.lowercased(),
                                               actualModel: "persisted-model", reason: "quota_exhausted", health: health, busy: false)
            let copy = try XCTUnwrap(view.preview?.copy)
            XCTAssertEqual(copy.title, "\(preferred.rawValue) can be tried")
            XCTAssertEqual(copy.detail, "No local quota block is currently recorded for \(preferred.rawValue). "
                           + "This chat stays with \(preferred.other.rawValue) until you switch.")
            XCTAssertEqual(copy.action, "Use \(preferred.rawValue)")
            XCTAssertTrue(view.canUsePreferred)
            XCTAssertEqual(view.actualProvider, preferred.other.rawValue.lowercased())
            XCTAssertEqual(view.actualModel, "persisted-model")
        }
    }
}
