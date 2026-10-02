import XCTest
@testable import WatchtowerCore

/// `ExternalConnectionTools` decodes `connections tools --json` and builds
/// the next `--allow` list for one toggle (QC-02).
final class ExternalConnectionToolsTests: XCTestCase {
    private typealias Tool = ExternalConnectionTools.Tool

    private func list(explicit: Bool = false, _ tools: [Tool]) -> ExternalConnectionTools {
        ExternalConnectionTools(id: 7, name: "jira", listed: true, listedAt: "2026-01-01T00:00:00Z",
                                explicit: explicit, stale: false, tools: tools)
    }

    func testDecodesTheCLIWireShape() throws {
        let json = #"""
        {"id":7,"name":"jira","listed":true,"listed_at":"2026-01-01T00:00:00Z","explicit":false,
         "tools":[{"name":"getIssue","allowed":true,"read_only":true,"write":false},
                  {"name":"createIssue","allowed":false,"read_only":false,"write":true},
                  {"name":"runQuery","allowed":false,"read_only":false,"write":false}]}
        """#
        let decoded = try JSONDecoder().decode(ExternalConnectionTools.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, list([
            Tool(name: "getIssue", allowed: true, readOnly: true, write: false),
            Tool(name: "createIssue", allowed: false, readOnly: false, write: true),
            Tool(name: "runQuery", allowed: false, readOnly: false, write: false)
        ]))
        XCTAssertEqual(decoded.tools.map(\.kind), [.readOnly, .write, .unmarked])
        XCTAssertEqual(decoded.tools.map(\.canToggle), [true, false, true], "a declared write has no toggle")
    }

    /// The never-listed shape: no listed_at, an empty array (not null), and
    /// an older CLI without the `write` field still decodes.
    func testDecodesTheNeverListedShapeAndAMissingWriteField() throws {
        let json = #"{"id":7,"name":"jira","listed":false,"explicit":false,"tools":[]}"#
        let decoded = try JSONDecoder().decode(ExternalConnectionTools.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.stale, "a CLI without the field never reports a stale list")
        XCTAssertFalse(decoded.listed)
        XCTAssertNil(decoded.listedAt)
        XCTAssertTrue(decoded.tools.isEmpty)

        let old = #"{"name":"createIssue","allowed":false,"read_only":false}"#
        XCTAssertFalse(try JSONDecoder().decode(Tool.self, from: Data(old.utf8)).write)
    }

    func testDecodesAStaleList() throws {
        let json = #"{"id":7,"name":"jira","listed":false,"explicit":true,"stale":true,"tools":[]}"#
        let decoded = try JSONDecoder().decode(ExternalConnectionTools.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.stale)
        XCTAssertFalse(decoded.listed)
    }

    func testListAndDefaultArgs() {
        XCTAssertEqual(ExternalConnectionTools.listArgs(id: 7), ["connections", "tools", "7", "--json"])
        XCTAssertEqual(ExternalConnectionTools.listArgs(id: 7, refresh: true),
                       ["connections", "tools", "7", "--refresh", "--json"])
        XCTAssertEqual(ExternalConnectionTools.defaultArgs(id: 7), ["connections", "tools", "7", "--default", "--json"])
    }

    func testAllowingAnUnmarkedToolWritesAnExplicitList() {
        let tools = list([
            Tool(name: "getIssue", allowed: true, readOnly: true, write: false),
            Tool(name: "createIssue", allowed: false, readOnly: false, write: true),
            Tool(name: "runQuery", allowed: false, readOnly: false, write: false)
        ])
        XCTAssertEqual(tools.allowArgs(setting: "runQuery", allowed: true),
                       ["connections", "tools", "7", "--allow=getIssue", "--allow=runQuery", "--json"])
    }

    func testTurningOffTheLastToolWritesAnEmptyList() {
        let tools = list([Tool(name: "getIssue", allowed: true, readOnly: true, write: false)])
        XCTAssertEqual(tools.allowArgs(setting: "getIssue", allowed: false),
                       ["connections", "tools", "7", "--allow=", "--json"])
    }

    /// A set equal to the read-only default goes back to `--default`, so
    /// tools the server adds later keep following the default.
    func testReturningToTheReadOnlySetUsesDefault() {
        let tools = list(explicit: true, [
            Tool(name: "getIssue", allowed: false, readOnly: true, write: false),
            Tool(name: "listIssues", allowed: true, readOnly: true, write: false),
            Tool(name: "runQuery", allowed: true, readOnly: false, write: false)
        ])
        XCTAssertEqual(tools.allowArgs(setting: "runQuery", allowed: false),
                       ["connections", "tools", "7", "--allow=listIssues", "--json"])
        let afterOff = list(explicit: true, [
            Tool(name: "getIssue", allowed: false, readOnly: true, write: false),
            Tool(name: "listIssues", allowed: true, readOnly: true, write: false)
        ])
        XCTAssertEqual(afterOff.allowArgs(setting: "getIssue", allowed: true),
                       ExternalConnectionTools.defaultArgs(id: 7))
    }

    /// A declared write is never carried into the list (it is never
    /// allowed), so `--allow` is not refused because of an old entry.
    func testADeclaredWriteNeverRidesAlong() {
        let tools = list(explicit: true, [
            Tool(name: "getIssue", allowed: true, readOnly: true, write: false),
            Tool(name: "deleteIssue", allowed: false, readOnly: false, write: true),
            Tool(name: "runQuery", allowed: false, readOnly: false, write: false)
        ])
        XCTAssertEqual(tools.allowArgs(setting: "runQuery", allowed: true),
                       ["connections", "tools", "7", "--allow=getIssue", "--allow=runQuery", "--json"])
    }
}
