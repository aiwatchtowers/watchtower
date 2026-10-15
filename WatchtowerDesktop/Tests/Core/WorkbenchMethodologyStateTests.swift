import XCTest
import WatchtowerCore
import WatchtowerTestSupport

/// Spec 2026-10-15 §8: the Agent settings read Go's `workbench methodology
/// --json` and show each effective value with where it comes from.
final class WorkbenchMethodologyStateTests: XCTestCase {
    private static let envelope = WorkbenchMethodologyFixtures.envelope

    private func decode(_ text: String = envelope) throws -> WorkbenchMethodologyState {
        try JSONDecoder().decode(WorkbenchMethodologyState.self, from: Data(text.utf8))
    }

    func testDecodesTheEnvelope() throws {
        let state = try decode()
        XCTAssertEqual(state.id, 7)
        XCTAssertEqual(state.personal.askGuard, "soft")
        XCTAssertEqual(state.effective[.finishCheck], "off")
        XCTAssertEqual(state.sources[.finishCheck], "file")
        XCTAssertTrue(state.file.present)
        XCTAssertEqual(state.file.bodyChars, 40)
        XCTAssertNil(state.failure)
    }

    func testChoiceIsThePersonalValueElseFromFile() throws {
        let state = try decode()
        XCTAssertEqual(state.choice(.askGuard), "soft")
        XCTAssertEqual(state.choice(.preset), WorkbenchMethodologyKey.fromFile)
    }

    func testEffectiveLineOnlyUnderFromFile() throws {
        let state = try decode()
        XCTAssertNil(state.effectiveLine(.askGuard), "a personal value needs no line")
        XCTAssertEqual(state.effectiveLine(.finishCheck), "Now Off, from .watchtower/workflow.md")
        XCTAssertEqual(state.effectiveLine(.preset), "Now Watchtower flow, the built-in default")
    }

    func testFileButtonAndNote() throws {
        XCTAssertEqual(try decode().fileButtonTitle, "Open workflow.md")
        XCTAssertNil(try decode().fileNote)
        let missing = Self.envelope.replacingOccurrences(of: #""present":true"#, with: #""present":false"#)
        XCTAssertEqual(try decode(missing).fileButtonTitle, "Create workflow.md")
        let broken = Self.envelope.replacingOccurrences(of: #""present":true,"error":"""#,
                                                        with: #""present":true,"error":"line 2: unknown key \"mode\"""#)
        XCTAssertEqual(try decode(broken).fileNote,
                       #"workflow.md was ignored: line 2: unknown key "mode". The built-in defaults apply."#)
    }

    func testFailureNamesWhatFailed() throws {
        let notSaved = Self.envelope.replacingOccurrences(of: #""ok":true,"error":"""#, with: #""ok":false,"error":"database is locked""#)
        XCTAssertEqual(try decode(notSaved).failure, "Could not save the setting: database is locked")
        let notInstalled = Self.envelope.replacingOccurrences(
            of: #""install_ran":false,"install_ok":true,"install_error":"""#,
            with: #""install_ran":true,"install_ok":false,"install_error":"permission denied""#)
        XCTAssertEqual(try decode(notInstalled).failure,
                       "The setting was saved, but the folder's skills were not updated: permission denied. Use Re-run Setup.")
        let notCreated = Self.envelope.replacingOccurrences(of: #""file_create_error":"""#, with: #""file_create_error":"read-only""#)
        XCTAssertEqual(try decode(notCreated).failure, "Could not create workflow.md: read-only")
    }

    func testKeysFlagsChoicesAndLabels() {
        XCTAssertEqual(WorkbenchMethodologyKey.allCases.map(\.flag), ["--preset", "--ask-guard", "--finish-check"])
        XCTAssertEqual(WorkbenchMethodologyKey.askGuard.choices, ["file", "strict", "soft", "off"])
        XCTAssertEqual(WorkbenchMethodologyKey.preset.choices, ["file", "watchtower-flow", "none"])
        XCTAssertEqual(WorkbenchMethodologyKey.finishCheck.choices, ["file", "on", "off"])
        XCTAssertEqual(WorkbenchMethodologyKey.preset.label("watchtower-flow"), "Watchtower flow")
        XCTAssertEqual(WorkbenchMethodologyKey.askGuard.label("file"), "From folder file")
        XCTAssertEqual(WorkbenchMethodologyKey.askGuard.label("soft"), "Soft")
        XCTAssertTrue(WorkbenchMethodologyKey.askGuard.help("soft").contains("Watchtower app running"),
                      "spec §7.1: soft's Desktop-down limit is in the help")
        for key in WorkbenchMethodologyKey.allCases {
            for choice in key.choices {
                XCTAssertFalse(key.help(choice).isEmpty, "\(key) \(choice)")
            }
        }
    }
}
