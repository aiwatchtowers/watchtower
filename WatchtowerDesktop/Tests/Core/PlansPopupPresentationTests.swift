import Foundation
import XCTest
@testable import WatchtowerCore

final class PlansPopupPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func limit(_ key: String, label: String, percent: Double, minutes: Int = 300) -> PlanUsageLimit {
        PlanUsageLimit(key: key, label: label, group: minutes == 300 ? "session" : "weekly", percent: percent,
                       resetsAt: now.addingTimeInterval(3600), severity: nil,
                       projection: PlanUsageProjection(state: percent >= 100 ? "hit" : "collecting", hitAt: nil, ratePerHour: 0),
                       windowDurationMinutes: minutes)
    }

    private func status(_ limits: [PlanUsageLimit], identity: Bool = true) -> PlanUsageStatus {
        PlanUsageStatus(state: "ok", reason: "", plan: "Plus", fetchedAt: now, lastError: "", limits: limits,
                        breakdown: [], provider: .codex, identityKnown: identity)
    }

    func testBucketDecodingUsesGoUTF8LengthAndRejectsMalformedSuffix() {
        XCTAssertEqual(PlansQuotaBucket.identifier("9:rév:🚀:primary:300"), "rév:🚀")
        XCTAssertEqual(PlansQuotaBucket.identifier("9:rév:🚀:secondary:10080"), "rév:🚀")
        for key in ["8:rév:🚀:primary:300", "99:short:primary:300", "opaque", "5:codex:other:300",
                    "5:codex:primary:300:extra", "-1:x:primary:300"] {
            XCTAssertNil(PlansQuotaBucket.identifier(key), key)
        }
    }

    func testGroupingPreservesAllQuotasAndExistingRestrictiveSelection() throws {
        let limits = [limit("9:rév:🚀:secondary:10080", label: "Weekly · Review quota", percent: 33, minutes: 10080),
                      limit("5:codex:secondary:10080", label: "Weekly · Codex", percent: 42, minutes: 10080),
                      limit("9:rév:🚀:primary:300", label: "5 hours · Review quota", percent: 100),
                      limit("5:codex:primary:300", label: "5 hours · Codex", percent: 17),
                      limit("codex", label: "Opaque quota", percent: 26)]
        let source = status(limits)
        let screen = PlansScreenPresentation(claude: nil, codex: source, now: now)
        let model = PlansPopupPresentation(screen: screen)
        let codex = model.providers[1]
        XCTAssertEqual(codex.groups.map(\.title), ["Codex", "Review quota", "Opaque quota"])
        XCTAssertEqual(codex.groups[0].quotas.map(\.duration), ["5h", "7d"])
        XCTAssertEqual(Set(codex.groups.flatMap(\.quotas).map(\.id)), Set(limits.map(\.key)))
        XCTAssertEqual(codex.groups.flatMap(\.quotas).filter(\.isSelected).map(\.id), ["9:rév:🚀:primary:300"])
        XCTAssertEqual(codex.groups.flatMap(\.quotas).first(where: \.isSelected)?.id,
                       try PlansPresentation.mostRestrictive(source, now: now)?.key)
    }

    func testUnknownIdentityUsesCurrentUsageAndSameProviderMessageOnlyOnce() {
        let screen = PlansScreenPresentation(claude: nil,
                                             codex: status([limit("5:codex:primary:300", label: "5 hours", percent: 51)], identity: false),
                                             now: now)
        let codex = PlansPopupPresentation(screen: screen).providers[1]
        XCTAssertEqual(codex.message, "Current usage only — account identity is unavailable.")
        XCTAssertEqual(codex.groups.flatMap(\.quotas).count, 1)
        XCTAssertTrue(codex.groups.flatMap(\.quotas).allSatisfy { $0.forecast == nil })
        XCTAssertTrue(codex.groups[0].quotas[0].isSelected)
    }

    func testPopupStateAndActionCopy() {
        let errorScreen = PlansScreenPresentation(claude: nil, codex: nil,
                                                  errors: [.codex: PlansOperationError(code: "network")], now: now)
        let error = PlansPopupPresentation(screen: errorScreen)
        XCTAssertEqual(error.freshness, "Needs attention")
        XCTAssertEqual(error.providers[1].action, "Retry Codex")
        XCTAssertEqual(error.providers[1].message, "Couldn't update Codex limits. Retry to update.")
        let loading = PlansPopupPresentation(screen: PlansScreenPresentation(claude: nil, codex: nil,
                                                                             refreshing: Set(PlanUsageProvider.allCases), now: now))
        XCTAssertEqual(loading.freshness, "Refreshing…")
        XCTAssertFalse(loading.canRefresh)
        XCTAssertTrue(loading.providers.allSatisfy { !$0.canRefresh })
        XCTAssertEqual(PlansPopupCopy.selected, "In menu bar")
        XCTAssertEqual(PlansPopupCopy.actions, "Watchtower actions")
    }
}
