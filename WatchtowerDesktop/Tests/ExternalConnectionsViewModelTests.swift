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
}
