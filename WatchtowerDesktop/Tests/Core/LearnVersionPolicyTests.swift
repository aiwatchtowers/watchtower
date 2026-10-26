import XCTest
@testable import WatchtowerCore

/// Plan D3: which cards are new on a launch.
final class LearnVersionPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let now = Date(timeIntervalSince1970: 1_792_900_000)
    private let day: TimeInterval = 24 * 60 * 60

    override func setUp() {
        suite = "LearnVersionPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func policy(_ workspace: String = "acme") -> LearnVersionPolicy {
        LearnVersionPolicy(defaults: defaults, workspace: workspace)
    }

    func testVersionParseAndCompare() {
        XCTAssertEqual(LearnVersion("0.25.0"), LearnVersion(major: 0, minor: 25, patch: 0))
        XCTAssertEqual(LearnVersion("v0.25.1-dev"), LearnVersion(major: 0, minor: 25, patch: 1))
        XCTAssertEqual(LearnVersion("0.19.0-12-gabc-dirty"), LearnVersion(major: 0, minor: 19, patch: 0))
        XCTAssertNil(LearnVersion("dev"))
        XCTAssertNil(LearnVersion("next"))
        XCTAssertNil(LearnVersion("0.25"))
        XCTAssertNil(LearnVersion("0..1"))
        // Numeric, not lexical.
        XCTAssertLessThan(LearnVersion(major: 0, minor: 9, patch: 0), LearnVersion(major: 0, minor: 10, patch: 0))
        XCTAssertEqual(LearnVersion.badge("0.25.3"), "0.25")
        XCTAssertEqual(LearnVersion.badge("next"), "next")
    }

    func testFreshInstallHasNothingNew() {
        XCTAssertNil(policy().newAfter(currentVersion: "0.25.0", onboardingFinished: false, now: now))
        XCTAssertEqual(defaults.string(forKey: "learn.lastVersion.acme"), "0.25.0")
        // The next launch of the same version: still nothing new.
        XCTAssertNil(policy().newAfter(currentVersion: "0.25.0", onboardingFinished: true, now: now + day))
    }

    func testFirstReleaseWithLearnCountsAsUpdatedFromThePreviousMinor() {
        let after = policy().newAfter(currentVersion: "0.25.0", onboardingFinished: true, now: now)
        XCTAssertEqual(after, LearnVersion(major: 0, minor: 24, patch: 0))
        XCTAssertEqual(defaults.object(forKey: "learn.newSince.acme") as? Date, now)
        // Same answer on a later launch inside the window.
        XCTAssertEqual(
            policy().newAfter(currentVersion: "0.25.0", onboardingFinished: true, now: now + day), after)
    }

    func testNormalUpdate() {
        _ = policy().newAfter(currentVersion: "0.24.2", onboardingFinished: true, now: now - 30 * day)
        let after = policy().newAfter(currentVersion: "0.25.1", onboardingFinished: true, now: now)
        XCTAssertEqual(after, LearnVersion(major: 0, minor: 24, patch: 2))
        XCTAssertEqual(defaults.string(forKey: "learn.lastVersion.acme"), "0.25.1")
    }

    func testWindowEndsAfter14Days() {
        _ = policy().newAfter(currentVersion: "0.24.0", onboardingFinished: true, now: now - 30 * day)
        XCTAssertNotNil(policy().newAfter(currentVersion: "0.25.0", onboardingFinished: true, now: now))
        XCTAssertNotNil(policy().newAfter(currentVersion: "0.25.0", onboardingFinished: true, now: now + 13 * day))
        XCTAssertNil(policy().newAfter(currentVersion: "0.25.0", onboardingFinished: true, now: now + 14 * day))
    }

    func testDevBuildIsFreshAndLeavesTheMemoryAlone() {
        _ = policy().newAfter(currentVersion: "0.24.0", onboardingFinished: true, now: now)
        XCTAssertNil(policy().newAfter(currentVersion: "dev", onboardingFinished: true, now: now))
        XCTAssertEqual(defaults.string(forKey: "learn.lastVersion.acme"), "0.24.0")
    }

    func testDowngradeShowsNothingNew() {
        _ = policy().newAfter(currentVersion: "0.24.0", onboardingFinished: true, now: now - day)
        _ = policy().newAfter(currentVersion: "0.25.0", onboardingFinished: true, now: now)
        XCTAssertNil(policy().newAfter(currentVersion: "0.24.0", onboardingFinished: true, now: now + day))
    }

    func testPerWorkspace() {
        _ = policy("acme").newAfter(currentVersion: "0.24.0", onboardingFinished: true, now: now - day)
        XCTAssertNotNil(policy("acme").newAfter(currentVersion: "0.25.0", onboardingFinished: true, now: now))
        XCTAssertNil(policy("other").newAfter(currentVersion: "0.25.0", onboardingFinished: false, now: now))
    }
}
