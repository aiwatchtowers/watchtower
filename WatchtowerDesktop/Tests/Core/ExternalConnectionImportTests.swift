import XCTest
@testable import WatchtowerCore

final class ExternalConnectionImportTests: XCTestCase {

    func testDecodesListWithSkipAndOmittedFields() throws {
        let json = """
            {"servers":[
              {"name":"tracker","source":"codex","kind":"stdio","command":"npx","args":["-y","t"],"has_secret":true},
              {"name":"legacy","source":"claude","kind":"sse","url":"https://legacy.example.com/sse","has_secret":false,
               "skip":"its sse transport is not supported (only stdio and http)"}
            ],"warnings":[]}
            """
        let list = try JSONDecoder().decode(ExternalConnectionImportList.self, from: Data(json.utf8))
        XCTAssertEqual(list.servers.count, 2)
        XCTAssertTrue(list.servers[0].canImport)
        XCTAssertEqual(list.servers[0].target, "npx")
        XCTAssertFalse(list.servers[1].canImport)
        XCTAssertEqual(list.servers[1].command, nil)
    }

    /// A server its config turned off is listed but not ticked; a rename
    /// carries its reason.
    func testDisabledAndRenamedServers() throws {
        let json = """
            {"servers":[
              {"name":"paused","source":"codex","kind":"stdio","command":"srv","enabled":false,"has_secret":false},
              {"name":"notes-2","source":"claude","kind":"http","url":"https://notes.example.com/mcp","enabled":true,
               "has_secret":false,"note":"named notes-2: notes is taken by another server"}
            ],"warnings":[]}
            """
        let list = try JSONDecoder().decode(ExternalConnectionImportList.self, from: Data(json.utf8))
        XCTAssertTrue(list.servers[0].canImport)
        XCTAssertFalse(list.servers[0].pickedByDefault)
        XCTAssertTrue(list.servers[1].pickedByDefault)
        XCTAssertEqual(list.servers[1].note, "named notes-2: notes is taken by another server")
    }

    /// Go initialises both slices, so the empty state decodes.
    func testDecodesEmptyList() throws {
        let list = try JSONDecoder().decode(
            ExternalConnectionImportList.self, from: Data(#"{"servers":[],"warnings":[]}"#.utf8))
        XCTAssertTrue(list.servers.isEmpty)
        XCTAssertTrue(list.warnings.isEmpty)
    }

    func testDecodesResults() throws {
        let json = """
            [{"name":"tracker","id":4,"status":"ok","sign_in":false},
             {"name":"notes","id":5,"status":"error","error":"listing failed","sign_in":true},
             {"name":"nope","error":"not found","sign_in":false}]
            """
        let results = try JSONDecoder().decode([ExternalConnectionImportResult].self, from: Data(json.utf8))
        XCTAssertNil(results[0].failure)
        XCTAssertTrue(results[1].signIn)
        XCTAssertNil(results[1].failure, "a created row that needs a sign-in is not a failure")
        XCTAssertEqual(results[2].failure, "nope: not found")
    }

    /// Names follow `--`, so cobra never reads one as a flag.
    func testArgs() {
        XCTAssertEqual(ExternalConnectionImportList.listArgs, ["connections", "import", "--json"])
        XCTAssertEqual(
            ExternalConnectionImportList.importArgs(names: ["a", "b"]),
            ["connections", "import", "--json", "--", "a", "b"])
    }
}
