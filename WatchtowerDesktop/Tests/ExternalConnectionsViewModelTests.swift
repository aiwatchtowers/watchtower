import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ExternalConnectionsViewModelTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    // MARK: - refresh

    func testRefreshPopulatesConnectionsFromDB() async throws {
        let pool = try makePool()
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO external_connections (name, kind, command, args_json, enabled, status, error)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["local-fs", "stdio", "/usr/local/bin/fs-mcp", "[\"--root\",\"/tmp\"]", true, "ok", ""])
        }
        let vm = ExternalConnectionsViewModel(dbPool: pool)
        XCTAssertTrue(vm.connections.isEmpty)

        await vm.refreshAsync()

        XCTAssertEqual(vm.connections.count, 1)
        XCTAssertEqual(vm.connections[0].name, "local-fs")
    }

    func testRefreshReplacesStaleConnections() async throws {
        let pool = try makePool()
        let id = try await pool.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO external_connections (name, kind) VALUES (?, ?)",
                arguments: ["local-fs", "stdio"])
            return db.lastInsertedRowID
        }
        let vm = ExternalConnectionsViewModel(dbPool: pool)
        await vm.refreshAsync()
        XCTAssertEqual(vm.connections.count, 1)

        try await pool.write { db in try db.execute(sql: "DELETE FROM external_connections WHERE id = ?", arguments: [id]) }
        await vm.refreshAsync()

        XCTAssertTrue(vm.connections.isEmpty)
    }

    // MARK: - addArgs (pure)

    func testAddArgsStdioWithCommandAndArgs() {
        let args = ExternalConnectionsViewModel.addArgs(
            name: "local-fs",
            kind: "stdio",
            command: "/usr/local/bin/fs-mcp",
            args: ["--root", "/tmp"],
            url: "",
            hasSecret: false
        )
        XCTAssertEqual(
            args,
            [
                "connections", "add",
                "--name", "local-fs",
                "--kind", "stdio",
                "--command", "/usr/local/bin/fs-mcp",
                "--arg", "--root",
                "--arg", "/tmp"
            ]
        )
    }

    func testAddArgsHTTPWithURL() {
        let args = ExternalConnectionsViewModel.addArgs(
            name: "remote-http",
            kind: "http",
            command: "",
            args: [],
            url: "https://example.com/mcp",
            hasSecret: false
        )
        XCTAssertEqual(
            args,
            ["connections", "add", "--name", "remote-http", "--kind", "http", "--url", "https://example.com/mcp"]
        )
    }

    func testAddArgsWithSecretAppendsSecretStdinFlagOnly() {
        let args = ExternalConnectionsViewModel.addArgs(
            name: "remote-http",
            kind: "http",
            command: "",
            args: [],
            url: "https://example.com/mcp",
            hasSecret: true
        )
        XCTAssertEqual(
            args,
            [
                "connections", "add",
                "--name", "remote-http",
                "--kind", "http",
                "--url", "https://example.com/mcp",
                "--secret-stdin"
            ]
        )
        // The secret payload never appears as an argument — only the flag does.
        XCTAssertFalse(args.contains { $0.contains("Bearer") || $0.contains("token") || $0.contains("{") })
    }

    func testAddArgsWithoutSecretOmitsFlag() {
        let args = ExternalConnectionsViewModel.addArgs(
            name: "local-fs",
            kind: "stdio",
            command: "/usr/local/bin/fs-mcp",
            args: [],
            url: "",
            hasSecret: false
        )
        XCTAssertFalse(args.contains("--secret-stdin"))
    }

    // MARK: - oauthArgs (pure)

    func testOAuthArgsAlwaysAppReturn() {
        XCTAssertEqual(
            ExternalConnectionsViewModel.oauthArgs(id: 7),
            ["connections", "oauth", "7", "--app-return"]
        )
    }

    // MARK: - setEnabledArgs (pure)

    func testSetEnabledArgsEnable() {
        let c = ExternalConnection(row: Row(["id": 2]))
        XCTAssertEqual(ExternalConnectionsViewModel.setEnabledArgs(for: c, enabled: true), ["connections", "enable", "2"])
    }

    func testSetEnabledArgsDisable() {
        let c = ExternalConnection(row: Row(["id": 2]))
        XCTAssertEqual(ExternalConnectionsViewModel.setEnabledArgs(for: c, enabled: false), ["connections", "disable", "2"])
    }

    // MARK: - removeArgs (pure)

    func testRemoveArgs() {
        let c = ExternalConnection(row: Row(["id": 3]))
        XCTAssertEqual(ExternalConnectionsViewModel.removeArgs(for: c), ["connections", "remove", "3"])
    }

    // MARK: - Tools (QC-02)

    private static func toolsJSON(_ tools: [(String, Bool, Bool, Bool)], explicit: Bool = false) -> Data {
        let rows = tools.map { #"{"name":"\#($0.0)","allowed":\#($0.1),"read_only":\#($0.2),"write":\#($0.3)}"# }
        return Data(#"""
            {"id":3,"name":"jira","listed":true,"listed_at":"2026-01-01T00:00:00Z","explicit":\#(explicit),
             "tools":[\#(rows.joined(separator: ","))]}
            """#.utf8)
    }

    private func makeToolsVM(_ runner: ScriptedToolsRunner?) throws -> (ExternalConnectionsViewModel, ExternalConnection) {
        let vm = ExternalConnectionsViewModel(dbPool: try makePool()) { runner }
        return (vm, ExternalConnection(row: Row(["id": 3, "name": "jira"])))
    }

    func testLoadToolsStoresTheCLIList() async throws {
        let runner = ScriptedToolsRunner { _ in
            Self.toolsJSON([("getIssue", true, true, false), ("createIssue", false, false, true)])
        }
        let (vm, c) = try makeToolsVM(runner)

        await vm.loadTools(c)

        XCTAssertEqual(runner.invocations, [["connections", "tools", "3", "--json"]])
        XCTAssertEqual(vm.toolLists[3]?.tools.map(\.kind), [.readOnly, .write])
        XCTAssertNil(vm.toolsErrors[3])
        XCTAssertFalse(vm.toolsInFlight.contains(3))
    }

    func testRefreshToolsAsksTheServerAgain() async throws {
        let runner = ScriptedToolsRunner { _ in Self.toolsJSON([("getIssue", true, true, false)]) }
        let (vm, c) = try makeToolsVM(runner)

        await vm.refreshTools(c)

        XCTAssertEqual(runner.invocations, [["connections", "tools", "3", "--refresh", "--json"]])
        XCTAssertNotNil(vm.toolLists[3])
    }

    /// The toggle re-reads the list right before writing: a tool allowed
    /// meanwhile (on screen it is still off) is kept, not dropped.
    func testSetToolBuildsTheListFromAFreshRead() async throws {
        var screen = true
        let runner = ScriptedToolsRunner { args in
            if args.contains("--allow=getIssue") {
                return Self.toolsJSON([("getIssue", true, true, false), ("runQuery", true, false, false),
                                       ("searchIssues", true, false, false)], explicit: true)
            }
            if screen { // what the owner saw
                return Self.toolsJSON([("getIssue", true, true, false), ("runQuery", false, false, false),
                                       ("searchIssues", false, false, false)])
            }
            // the CLI allowed searchIssues meanwhile
            return Self.toolsJSON([("getIssue", true, true, false), ("runQuery", false, false, false),
                                   ("searchIssues", true, false, false)], explicit: true)
        }
        let (vm, c) = try makeToolsVM(runner)
        await vm.loadTools(c)
        screen = false

        await vm.setTool("runQuery", allowed: true, on: c)

        XCTAssertEqual(runner.invocations.last,
                       ["connections", "tools", "3", "--allow=getIssue", "--allow=runQuery",
                        "--allow=searchIssues", "--json"])
        XCTAssertEqual(vm.toolLists[3]?.tools.filter(\.allowed).count, 3)
        XCTAssertEqual(vm.toolLists[3]?.explicit, true)
    }

    /// A refusal keeps the list on screen and shows the CLI's own message.
    func testARefusedChangeShowsTheCLIMessage() async throws {
        let runner = ScriptedToolsRunner { args in
            if args.contains(where: { $0.hasPrefix("--allow") }) {
                throw CLIRunnerError.nonZeroExit(
                    code: 1, stderr: "2026/01/01 00:00:00 external MCP: a log line\n--allow: \"x\" is a write tool\n\n")
            }
            return Self.toolsJSON([("x", false, false, false)])
        }
        let (vm, c) = try makeToolsVM(runner)
        await vm.loadTools(c)

        await vm.setTool("x", allowed: true, on: c)

        XCTAssertEqual(vm.toolsErrors[3], "--allow: \"x\" is a write tool", "the last stderr line, not the log")
        XCTAssertEqual(vm.toolLists[3]?.tools.first?.allowed, false, "the list on screen is unchanged")
        XCTAssertFalse(vm.toolsInFlight.contains(3))

        await vm.loadTools(c)
        XCTAssertNil(vm.toolsErrors[3], "the next successful command clears the error")
    }

    /// A re-listing dropped the tool: nothing is written, the fresh list
    /// replaces the stale one, and the owner is told.
    func testTogglingAToolTheServerDroppedWritesNothing() async throws {
        var listing = Self.toolsJSON([("getIssue", true, true, false), ("runQuery", false, false, false)])
        let runner = ScriptedToolsRunner { _ in listing }
        let (vm, c) = try makeToolsVM(runner)
        await vm.loadTools(c)
        listing = Self.toolsJSON([("getIssue", true, true, false)])

        await vm.setTool("runQuery", allowed: true, on: c)

        XCTAssertEqual(runner.invocations.count, 2, "only reads, no --allow")
        XCTAssertEqual(vm.toolLists[3]?.tools.map(\.name), ["getIssue"])
        XCTAssertTrue(vm.toolsErrors[3]?.contains("runQuery is no longer") == true)
    }

    /// A write whose output cannot be read may have landed: the old toggles
    /// are dropped rather than shown as current.
    func testUnreadableOutputAfterAWriteDropsTheStaleList() async throws {
        let runner = ScriptedToolsRunner { args in
            args.contains("--default") ? Data("garbled".utf8) : Self.toolsJSON([("getIssue", true, true, false)])
        }
        let (vm, c) = try makeToolsVM(runner)
        await vm.loadTools(c)

        await vm.useDefaultTools(c)

        XCTAssertNil(vm.toolLists[3])
        XCTAssertNotNil(vm.toolsErrors[3])
    }

    func testUnreadableOutputIsAnErrorNotAnEmptyList() async throws {
        let runner = ScriptedToolsRunner { _ in Data("not json".utf8) }
        let (vm, c) = try makeToolsVM(runner)

        await vm.loadTools(c)

        XCTAssertNil(vm.toolLists[3])
        XCTAssertTrue(vm.toolsErrors[3]?.hasPrefix("Could not read the tool list") == true)
    }

    func testMissingCLIIsVisible() async throws {
        let (vm, c) = try makeToolsVM(nil)

        await vm.loadTools(c)

        XCTAssertEqual(vm.toolsErrors[3], "Watchtower CLI not found")
    }

    func testUseDefaultToolsArgs() async throws {
        let runner = ScriptedToolsRunner { _ in Self.toolsJSON([("getIssue", true, true, false)]) }
        let (vm, c) = try makeToolsVM(runner)

        await vm.useDefaultTools(c)

        XCTAssertEqual(runner.invocations, [["connections", "tools", "3", "--default", "--json"]])
    }
}

/// A `CLIRunnerProtocol` whose reply depends on the arguments.
private final class ScriptedToolsRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let reply: ([String]) throws -> Data
    private let lock = NSLock()
    private var calls: [[String]] = []

    init(_ reply: @escaping ([String]) throws -> Data) {
        self.reply = reply
    }

    var invocations: [[String]] {
        lock.withLock { calls }
    }

    func run(args: [String]) async throws -> Data {
        lock.withLock { calls.append(args) }
        return try reply(args)
    }
}
