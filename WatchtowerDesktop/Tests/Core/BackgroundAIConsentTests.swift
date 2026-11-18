import Foundation
import XCTest
@testable import WatchtowerCore

/// BGAI-03: the Swift twin resolves the background AI consent exactly as Go's
/// `aiconsent.Resolve`, over the one shared fixture (the POLICY-02 pattern).
final class BackgroundAIConsentTests: XCTestCase {
    private typealias Consent = BackgroundAIConsent

    private static func fixture() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/aiconsent/testdata/consent_cases.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(obj as? [[String: Any]])
    }

    /// Every row of spec §3.2; the policy goes through `ManagedPolicy`
    /// first, so the wrong-type row reads as Go's `policy.Normalize` does.
    func testSharedFixture() throws {
        let cases = try Self.fixture()
        XCTAssertEqual(cases.count, 8, "spec §3.2 has 8 rows")
        for c in cases {
            let name = c["name"] as? String ?? "?"
            var raw: [String: Any] = [:]
            if let p = c["policy_raw"] { raw[ManagedPolicy.Key.allowBackgroundAI.rawValue] = p }
            let policy = ManagedPolicy.normalize(raw).allowBackgroundAI
            let got = Consent.resolve(answer: c["answer"] as? String, policy: policy)
            let want = try XCTUnwrap(c["want"] as? [String: Any], name)
            XCTAssertEqual(got.effective.rawValue, want["effective"] as? String, name)
            XCTAssertEqual(got.reason.rawValue, want["reason"] as? String, name)
            XCTAssertEqual(got.prompt, want["prompt"] as? Bool, name)
            XCTAssertEqual(got.locked, want["locked"] as? Bool, name)
            XCTAssertEqual(got.isAllowed, want["effective"] as? String == "allowed", name)
        }
    }

    /// An unknown value reads as not answered, as Go's `ParseAnswer`.
    func testUnknownAnswerReadsUnanswered() {
        XCTAssertEqual(Consent.resolve(answer: "yes", policy: nil), Consent.resolve(answer: nil, policy: nil))
        XCTAssertEqual(Consent.resolve(answer: "", policy: nil).reason, .unanswered)
        XCTAssertEqual(Consent.resolve(answer: "Allowed", policy: nil).reason, .unanswered)
    }

    func testAllowedByOwner() {
        XCTAssertEqual(Consent.resolve(answer: "allowed", policy: nil), Consent.State.allowedByOwner)
        XCTAssertTrue(Consent.State.allowedByOwner.isAllowed)
    }

    /// A config that exists but cannot be read reads paused whatever the
    /// profile says (Go `TestCurrent_UnreadableConfigWithPermissiveProfileIsPaused`).
    func testUnreadableConfigIsPausedEvenWithAPermissiveProfile() {
        let unanswered = Consent.resolve(answer: nil, policy: nil)
        XCTAssertEqual(Consent.resolve(answer: "allowed", readFailed: true, policy: nil), unanswered)
        XCTAssertEqual(Consent.resolve(answer: nil, readFailed: true, policy: true), unanswered)
        XCTAssertEqual(
            Consent.resolve(answer: "allowed", readFailed: true, policy: false),
            Consent.resolve(answer: nil, policy: false)
        )
    }

    /// A clean read is the plain resolve (a missing file is "not answered").
    func testCleanReadIsResolve() {
        for answer in [nil, "allowed", "paused"] {
            for policy in [nil, true, false] as [Bool?] { // swiftlint:disable:this discouraged_optional_boolean
                XCTAssertEqual(
                    Consent.resolve(answer: answer, readFailed: false, policy: policy),
                    Consent.resolve(answer: answer, policy: policy)
                )
            }
        }
    }
}
