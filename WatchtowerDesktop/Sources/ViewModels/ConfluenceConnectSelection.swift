import Foundation
import GRDB
import WatchtowerCore

/// The board step's Confluence selection (#573), run once per sheet after a
/// connect that asked for Confluence: inherits Settings' feature gate, reads
/// each added site's grant (`confluence access --json`) so a refused or
/// dropped Confluence scope is said in words, then runs `select --recent`
/// and names what got selected. The line is `ConfluenceConnectStep.line`.
@MainActor
@Observable
final class ConfluenceConnectSelection {
    private(set) var line: String?
    private(set) var isRunning = false

    private struct Access: Decodable { let read: Bool }

    private let dbPool: DatabasePool
    private let runner: CLIRunnerProtocol?
    private let isFeatureOff: @MainActor () -> Bool

    init(dbPool: DatabasePool, runner: CLIRunnerProtocol?, isFeatureOff: @escaping @MainActor () -> Bool) {
        self.dbPool = dbPool
        self.runner = runner
        self.isFeatureOff = isFeatureOff
    }

    /// Runs the selection; a second call does nothing.
    func run(accountIDsBefore: Set<Int>?) async {
        guard line == nil, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        line = ConfluenceConnectStep.line(await outcome(before: accountIDsBefore))
    }

    private func outcome(before: Set<Int>?) async -> ConfluenceConnectStep.Outcome {
        if isFeatureOff() { return .featureOff }
        guard let runner else { return .failed(["Watchtower CLI not found"]) }
        let added: [JiraAccount]
        do {
            let accounts = try await dbPool.read { db in try JiraAccountQueries.fetchAll(db) }
            added = ConfluenceConnectStep.addedSites(accounts, before: before)
        } catch {
            return .failed([error.localizedDescription])
        }
        guard !added.isEmpty else { return .noSite }
        var failures: [String] = []
        var granted: [JiraAccount] = []
        for site in added {
            do {
                let data = try await runner.run(args: ConfluenceConnectStep.accessArgs(accountID: site.id))
                guard let access = try? JSONDecoder().decode(Access.self, from: data) else {
                    failures.append("couldn't read Confluence access")
                    continue
                }
                guard access.read else { continue }
                granted.append(site)
                _ = try await runner.run(args: ConfluenceConnectStep.selectArgs(accountID: site.id))
            } catch {
                failures.append(ConfluenceConnectStep.failureText(Self.message(from: error)))
            }
        }
        if !failures.isEmpty { return .failed(failures) }
        if granted.isEmpty { return .notEnabled }
        let sites = granted
        do {
            let names = try await dbPool.read { db in
                try sites.flatMap { try ExtSourceQueries.fetchForJiraAccount(db, accountID: Int64($0.id)) }
                    .map(\.containerName)
            }
            return .selected(names)
        } catch {
            return .failed([error.localizedDescription])
        }
    }

    /// The CLI prints its error as the last stderr line (cmd/root.go).
    private static func message(from error: Error) -> String {
        if case let CLIRunnerError.nonZeroExit(code, stderr) = error {
            let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            return last.isEmpty ? "watchtower exited with code \(code)" : last
        }
        return error.localizedDescription
    }
}
