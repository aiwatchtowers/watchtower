import XCTest

/// Every `Test*` of relay@3a99bd7 `sim/sim_interop_test.go` has a Swift twin, under the same name
/// with a lower-case `test` prefix, in `RelaySimOrderTwins` or `RelaySimSwitchTwins` (Go parity).
/// The twin classes are found by name, so a missing or renamed one fails here.
final class RelaySimCensusTests: XCTestCase {
    /// The Go tests, in file order.
    static let goTests = [
        "TestActionsAppliedInOrderOnce",
        "TestGapTriggersResendFrom",
        "TestSkipToMarksUndelivered",
        "TestSwitchToCloudKitDuringRelayOutage",
        "TestSwitchToRelayRejectedWithin5Min",
        "TestSecondPhoneFollowsSwitch",
        "TestOldEpochActionAfter14DaysResealed",
        "TestNoCopiesLeftOnRelayAfterSwitch",
        "TestEntitlementExpiredFallsBackToCloudKit",
        "TestEntitlementExpiredOtherPayingPhoneKeepsHub",
        "TestLapsedPhoneActionAppliedBeforeHubKnewIsEchoed",
        "TestHubActsOnEntitlementControl",
        "TestStaleActionGetsSwitchAgain",
        "TestMarkerLeadsReturningPhone",
        "TestStaleSwitchedIgnored",
        "TestHubResendFromRetriedUntilWritten",
        "TestPhoneSkipToRetriedUntilWritten",
        "TestSwitchedRetriedWhenBothMailboxesFailed",
        "TestRefusedActionWriteRetried",
        "TestHubOnRelayTellsFreePhone"
    ]

    static let twinClasses = ["RelaySimOrderTwins", "RelaySimSwitchTwins"]

    func testEverySimTestHasATwin() throws {
        XCTAssertEqual(Self.goTests.count, 20)
        let module = String(reflecting: Self.self).split(separator: ".").first.map(String.init) ?? ""
        var twins: [String] = []
        for name in Self.twinClasses {
            let cls = try XCTUnwrap(NSClassFromString("\(module).\(name)") as? XCTestCase.Type, "no twin class \(name)")
            twins += Self.methodNames(cls.defaultTestSuite)
        }
        let want = Self.goTests.map { "test" + $0.dropFirst("Test".count) }
        XCTAssertEqual(twins.sorted(), want.sorted())
    }

    /// The test method names of a suite (`-[Module.Class testName]` → `testName`).
    private static func methodNames(_ suite: XCTestSuite) -> [String] {
        suite.tests.flatMap { test -> [String] in
            if let nested = test as? XCTestSuite { return methodNames(nested) }
            guard let method = test.name.split(separator: " ").last else { return [] }
            return [String(method.dropLast())]
        }
    }
}
