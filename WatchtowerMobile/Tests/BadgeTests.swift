import SwiftUI
import XCTest
@testable import WatchtowerMobile

/// The shared badge color mapper (Components/Badge.swift): every string the
/// Kit models emit (`statusColor` / `priorityColor`) must map explicitly —
/// "secondary" included — with the gray default reserved for genuinely
/// unknown names, never silently swallowing a known one.
final class BadgeTests: XCTestCase {

    func testColorMapsEveryKnownModelColorName() {
        XCTAssertEqual(color("red"), .red)
        XCTAssertEqual(color("orange"), .orange)
        XCTAssertEqual(color("green"), .green)
        XCTAssertEqual(color("blue"), .blue)
        XCTAssertEqual(color("purple"), .purple)
        XCTAssertEqual(color("gray"), .gray)
        // "secondary" is a KNOWN name (Target.statusColor for todo, the
        // priority mappings for low) — it must not fall into the gray default.
        XCTAssertEqual(color("secondary"), .secondary)
    }

    func testColorKeepsAGrayDefaultForUnknownNames() {
        XCTAssertEqual(color("chartreuse"), .gray)
    }
}
