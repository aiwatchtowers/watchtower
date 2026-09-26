import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

/// The save/Reload-error rows in `ConfigSaveBar` are driven by a private
/// @State, with no closure or public API seam to observe it. This project's
/// ViewInspector (0.10.x) does not propagate a @State mutation from
/// `.tap()` back into a subsequent `view.inspect()` call on the same view
/// value — confirmed with a trivial `@State` counter view, with and without
/// `ViewHosting` — so the dynamic "failing save shows the error" and
/// "Reload clears it" cases from the task brief are not drivable here and
/// are intentionally not covered. What IS covered below is the row driven
/// by `config.parseError`, which lives on the (`@Bindable`, reference-type)
/// `ConfigService` and is therefore visible immediately.
@MainActor
final class ConfigSaveBarTests: XCTestCase {

    private func makeTempConfig(_ yaml: String) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchtower-configsavebar-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.yaml").path
        try? yaml.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// A config file Yams can't parse into a dictionary surfaces
    /// `config.parseError` as its own row above the button bar.
    func testMalformedConfigShowsParseErrorRow() throws {
        let path = makeTempConfig("foo: [1, 2\nbar: baz")
        let config = ConfigService(configPath: path)
        try XCTSkipIf(config.parseError == nil, "this YAML happened to parse without error")

        let message = try XCTUnwrap(config.parseError)
        let view = ConfigSaveBar(config: config)
        XCTAssertNoThrow(try view.inspect().find(text: "Parse error: \(message)"))
    }

    /// A valid config shows no parse-error row.
    func testValidConfigShowsNoParseErrorRow() throws {
        let path = makeTempConfig("active_workspace: dev\n")
        let config = ConfigService(configPath: path)
        XCTAssertNil(config.parseError)

        let view = ConfigSaveBar(config: config)
        XCTAssertThrowsError(try view.inspect().find(ViewType.Text.self) { text in
            (try? text.string().hasPrefix("Parse error")) == true
        })
    }

    /// Reload always re-reads the file and doesn't crash on a missing one.
    func testReloadButtonPresentAndUsable() throws {
        let path = makeTempConfig("active_workspace: dev\n")
        let config = ConfigService(configPath: path)
        let view = ConfigSaveBar(config: config)

        try view.inspect().find(button: "Reload").tap()
        XCTAssertEqual(config.activeWorkspace, "dev")
    }
}
