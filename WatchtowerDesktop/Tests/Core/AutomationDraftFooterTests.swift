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

    func testCompactSaveOnlyWhenHiddenAndSavable() {
        XCTAssertTrue(Footer.showsCompactSave(hidden: true, canSave: true))
        XCTAssertFalse(Footer.showsCompactSave(hidden: true, canSave: false))
        XCTAssertFalse(Footer.showsCompactSave(hidden: false, canSave: true))
        XCTAssertFalse(Footer.showsCompactSave(hidden: false, canSave: false))
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

    // MARK: - A built-in (C2): Save confirms; Save and Turn On while it is off

    private func builtin(bytes: Bool, enabled: Bool, needs: Bool = false, showsAll: Bool = true) -> Footer {
        Footer.make(isNew: false, bytesChanged: bytes, enabled: enabled, needsConfirmation: needs,
                    showsAllFields: showsAll, isBuiltin: true)
    }

    func testBuiltinFooterOffersSaveAndTurnOnWhenOff() {
        let save = "Saving confirms exactly what's listed above"
        let turnsOn = "Saving confirms exactly what's listed above and turns it on"
        for needs in [false, true] {
            assertRow(builtin(bytes: true, enabled: true, needs: needs), "Save", enabled: true, nil, save)
            assertRow(builtin(bytes: true, enabled: false, needs: needs), "Save and Turn On", enabled: true,
                      "Save", turnsOn)
        }
        // A hand-edited copy with no edits here: confirmed only, on/off stays on the card.
        for enabled in [false, true] {
            assertRow(builtin(bytes: false, enabled: enabled, needs: true), "Confirm", enabled: true, nil,
                      "Confirming approves exactly what's listed above")
            assertRow(builtin(bytes: false, enabled: enabled), "Save", enabled: false, nil, "No changes to save")
        }
        assertRow(builtin(bytes: true, enabled: false, showsAll: false), "Save", enabled: false, nil,
                  "Can't show everything this would confirm, so it can't be saved")
        XCTAssertEqual(Footer.Action.save.title, "Save")
    }

    func testBuiltinFooterHasNoDelete() {
        // Turning a built-in off is the card's Turn Off (its feature keys);
        // no footer button deletes it or saves it turned off.
        for bytes in [false, true] {
            for enabled in [false, true] {
                for needs in [false, true] {
                    let footer = builtin(bytes: bytes, enabled: enabled, needs: needs)
                    for action in [footer.primary] + (footer.secondary.map { [$0] } ?? []) {
                        XCTAssertFalse(action.title.contains("Delete"), "\(action)")
                        XCTAssertFalse([.saveTurnedOff, .confirmTurnedOff, .confirmAndTurnOn, .saveAndConfirm]
                            .contains(action), "\(bytes) \(enabled) \(needs): \(action)")
                    }
                }
            }
        }
    }
}
