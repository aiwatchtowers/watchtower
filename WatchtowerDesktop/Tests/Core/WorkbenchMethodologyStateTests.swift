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

    /// Board #558: a repo file asking to weaken a check is ignored, and the
    /// sheet says so, pointing at the owner's own settings.
    func testFileNoteNamesTheIgnoredChecks() throws {
        let asks = Self.envelope.replacingOccurrences(of: #""truncated":false"#,
                                                      with: #""truncated":false,"ignored":["ask_guard: off","finish_check: off"]"#)
        XCTAssertEqual(try decode(asks).file.ignored, ["ask_guard: off", "finish_check: off"])
        XCTAssertEqual(try decode(asks).fileNote,
                       "workflow.md asks for ask_guard: off, finish_check: off; that is ignored. "
                           + "Only your settings above can turn a check down: pick the value here to keep it.")
        let none = Self.envelope.replacingOccurrences(of: #""truncated":false"#, with: #""truncated":false,"ignored":[]"#)
        XCTAssertNil(try decode(none).fileNote)
        let cutToo = asks.replacingOccurrences(of: #""truncated":false"#, with: #""truncated":true"#)
        XCTAssertEqual(try decode(cutToo).fileNote,
                       "workflow.md is longer than 64 KiB; Watchtower reads only its first 64 KiB. "
                           + "workflow.md asks for ask_guard: off, finish_check: off; that is ignored. "
                           + "Only your settings above can turn a check down: pick the value here to keep it.")
        XCTAssertTrue(WorkbenchMethodologyKey.askGuard.choiceHelp("file").contains("cannot turn this check down"))
        XCTAssertTrue(WorkbenchMethodologyKey.preset.choiceHelp("file").contains("workflow.md, else the built-in default"))
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

    func testInstallNoteForAKeptPresetOrASingleFileCore() throws {
        XCTAssertNil(try decode().installNote)
        XCTAssertEqual(try decode().installFlow, "")
        let none = Self.envelope.replacingOccurrences(of: #""effective":{"preset":"watchtower-flow""#,
                                                      with: #""effective":{"preset":"none""#)
        for kept in ["drifted", "foreign"] {
            let text = none.replacingOccurrences(of: #""install_codex_flow":"""#, with: #""install_codex_flow":"\#(kept)""#)
            XCTAssertEqual(try decode(text).installNote,
                           "Your edited watchtower-flow skill was kept; delete it yourself to drop the methodology.")
        }
        let removed = none.replacingOccurrences(of: #""install_flow":"""#, with: #""install_flow":"removed""#)
        XCTAssertNil(try decode(removed).installNote)
        let editedUnderFlow = Self.envelope.replacingOccurrences(of: #""install_flow":"""#, with: #""install_flow":"drifted""#)
        XCTAssertNil(try decode(editedUnderFlow).installNote, "under watchtower-flow an edited preset is the preset")
        let single = Self.envelope.replacingOccurrences(of: #""install_single_file_layout":false"#,
                                                        with: #""install_single_file_layout":true"#)
        XCTAssertEqual(try decode(single).installNote,
                       "Your edited skill keeps the old single-file layout; delete it to take the v10 core and preset.")
    }

    func testKeysFlagsChoicesAndLabels() {
        XCTAssertEqual(WorkbenchMethodologyKey.allCases.map(\.flag), ["--preset", "--ask-guard", "--finish-check"])
        XCTAssertEqual(WorkbenchMethodologyKey.askGuard.choices, ["file", "strict", "soft", "off"])
        XCTAssertEqual(WorkbenchMethodologyKey.preset.choices, ["file", "watchtower-flow", "none"])
        XCTAssertEqual(WorkbenchMethodologyKey.finishCheck.choices, ["file", "on", "off"])
        XCTAssertEqual(WorkbenchMethodologyKey.preset.choiceLabel("watchtower-flow"), "Watchtower flow")
        XCTAssertEqual(WorkbenchMethodologyKey.askGuard.choiceLabel("file"), "Default", "board #558: the file never sets a check")
        XCTAssertEqual(WorkbenchMethodologyKey.finishCheck.choiceLabel("file"), "Default")
        XCTAssertEqual(WorkbenchMethodologyKey.preset.choiceLabel("file"), "From folder file")
        XCTAssertEqual(WorkbenchMethodologyKey.askGuard.choiceLabel("soft"), "Soft")
        XCTAssertTrue(WorkbenchMethodologyKey.askGuard.choiceHelp("soft").contains("Watchtower app running"),
                      "spec §7.1: soft's Desktop-down limit is in the help")
        XCTAssertTrue(WorkbenchMethodologyKey.askGuard.choiceHelp("soft").contains("only in sessions run in Watchtower's terminal"),
                      "soft records nothing outside a Watchtower terminal session")
        for key in WorkbenchMethodologyKey.allCases {
            for choice in key.choices {
                XCTAssertFalse(key.choiceHelp(choice).isEmpty, "\(key) \(choice)")
            }
        }
    }
}
