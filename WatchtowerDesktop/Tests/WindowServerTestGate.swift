import CoreGraphics
import Foundation
import XCTest

/// Skips a test class that needs a window server (real mouse and key events,
/// key windows) on the owner's Mac CI runners, which run outside a GUI
/// session (scripts/ci-runner/README.md, "Why not Swift Test"). Skips only
/// when BOTH hold: the Mac CI job set `WATCHTOWER_CI_NO_WINDOW_SERVER=1`, and
/// no window server is reachable right now. A dev machine or a cloud runner
/// never sets the variable, so the tests run (and fail loudly) there; the
/// `Swift UI Tests` job runs these classes on macos-26 after every main push.
enum WindowServerTestGate {
    static let envKey = "WATCHTOWER_CI_NO_WINDOW_SERVER"

    /// The skip message, or nil when the class runs.
    static func skipReason(environment: [String: String], windowServerReachable: Bool) -> String? {
        guard environment[envKey] == "1", !windowServerReachable else { return nil }
        return "no window server on this CI runner (\(envKey)=1); the Swift UI Tests job runs this class"
    }

    /// A process outside a GUI session gets no CGSession dictionary.
    static var windowServerReachable: Bool {
        CGSessionCopyCurrentDictionary() != nil
    }

    static func skipIfAbsent() throws {
        if let reason = skipReason(environment: ProcessInfo.processInfo.environment,
                                   windowServerReachable: windowServerReachable) {
            throw XCTSkip(reason)
        }
    }
}

final class WindowServerTestGateTests: XCTestCase {
    func testRunsUnlessTheCIJobAsksAndNoWindowServerAnswers() {
        let ci = [WindowServerTestGate.envKey: "1"]
        XCTAssertNil(WindowServerTestGate.skipReason(environment: [:], windowServerReachable: false),
                     "without the variable a missing window server fails the tests, never skips them")
        XCTAssertNil(WindowServerTestGate.skipReason(environment: [WindowServerTestGate.envKey: "0"], windowServerReachable: false))
        XCTAssertNil(WindowServerTestGate.skipReason(environment: ci, windowServerReachable: true),
                     "a runner with a window server runs them")
        XCTAssertNotNil(WindowServerTestGate.skipReason(environment: ci, windowServerReachable: false))
    }
}
