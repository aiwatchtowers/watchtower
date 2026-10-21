import XCTest
@testable import WatchtowerCore

final class AutomationDraftFooterTests: XCTestCase {
    private typealias Footer = AutomationDraftFooter

    private func assertRow(
        _ footer: Footer,
        _ primary: String,
        enabled: Bool,
        _ secondary: String?,
        _ hint: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(footer.primary.title, primary, file: file, line: line)
        XCTAssertEqual(footer.primaryEnabled, enabled, file: file, line: line)
        XCTAssertEqual(footer.secondary?.title, secondary, file: file, line: line)
        XCTAssertEqual(footer.hint, hint, file: file, line: line)
    }

    func testTable() {
        let turnsOn = "Saving confirms exactly what's listed above and turns it on"
        let save = "Saving confirms exactly what's listed above"
        let confirm = "Confirming approves exactly what's listed above"

        for (bytes, enabled, needs) in [(false, false, false), (true, true, true), (false, true, true)] {
            assertRow(Footer.make(isNew: true, bytesChanged: bytes, enabled: enabled, needsConfirmation: needs),
                      "Save and Turn On", enabled: true, "Save Turned Off", turnsOn)
        }
        for needs in [false, true] {
            assertRow(Footer.make(isNew: false, bytesChanged: true, enabled: true, needsConfirmation: needs),
                      "Save and Confirm", enabled: true, "Save Turned Off", save)
            assertRow(Footer.make(isNew: false, bytesChanged: true, enabled: false, needsConfirmation: needs),
                      "Save and Turn On", enabled: true, "Save Turned Off", turnsOn)
        }
        assertRow(Footer.make(isNew: false, bytesChanged: false, enabled: false, needsConfirmation: true),
                  "Confirm and Turn On", enabled: true, "Confirm Turned Off", confirm)
        assertRow(Footer.make(isNew: false, bytesChanged: false, enabled: true, needsConfirmation: true),
                  "Confirm", enabled: true, nil, confirm)
        for enabled in [false, true] {
            assertRow(Footer.make(isNew: false, bytesChanged: false, enabled: enabled, needsConfirmation: false),
                      "Save and Confirm", enabled: false, nil, "No changes to save")
        }
    }

    /// A column that cannot show every hashed field turns every button off
    /// (AUTO-06), whatever the row would offer.
    func testCantShowAllFieldsTurnsEverythingOff() {
        for (isNew, changed, enabled, needs) in [(true, true, false, false), (false, true, true, false),
                                                 (false, false, true, true), (false, false, false, true)] {
            let footer = Footer.make(isNew: isNew, bytesChanged: changed, enabled: enabled,
                                     needsConfirmation: needs, showsAllFields: false)
            XCTAssertFalse(footer.primaryEnabled)
            XCTAssertNil(footer.secondary)
            XCTAssertEqual(footer.hint, Footer.cantShowAllHint)
        }
    }

    func testInvalidRecipeSaysItHasErrors() {
        let footer = Footer.make(isNew: false, bytesChanged: true, enabled: true, needsConfirmation: false,
                                 showsAllFields: false, hasErrors: true)
        XCTAssertFalse(footer.primaryEnabled)
        XCTAssertNil(footer.secondary)
        XCTAssertEqual(footer.hint, "The recipe has errors, so it can't be saved")
    }

    func testActionTitles() {
        let titles: [AutomationDraftFooter.Action: String] = [
            .saveAndTurnOn: "Save and Turn On", .saveTurnedOff: "Save Turned Off", .saveAndConfirm: "Save and Confirm",
            .confirmAndTurnOn: "Confirm and Turn On", .confirmTurnedOff: "Confirm Turned Off", .confirm: "Confirm"
        ]
        for (action, title) in titles { XCTAssertEqual(action.title, title) }
    }
}
