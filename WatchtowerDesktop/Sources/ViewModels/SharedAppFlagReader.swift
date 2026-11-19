import Foundation
import WatchtowerCore

/// Which Google or Jira accounts Go reports on a retiring shared app
/// (`google accounts --json` `shared_gmail`, `jira accounts --json`
/// `shared_atlassian`, #1887 T19): the banners of company screens spec §7
/// and the rows' **Shared app** tag. Go owns the client resolver that
/// decides it; this only reads the flags.
///
/// Empty before the first successful read, so a failed one shows no banner;
/// a later failure keeps the last answer (logged, never shown: the detail
/// works without it). Reads finish out of order: only a newer read's answer
/// replaces the ids.
@MainActor
@Observable
final class SharedAppFlagReader {
    private(set) var accountIDs: Set<Int> = []
    @ObservationIgnored private let args: [String]
    @ObservationIgnored private let flag: String
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var applied = 0

    init(args: [String], flag: String) {
        self.args = args
        self.flag = flag
    }

    static func google() -> SharedAppFlagReader {
        SharedAppFlagReader(args: SharedAppFlags.googleArgs, flag: SharedAppFlags.googleFlag)
    }

    static func jira() -> SharedAppFlagReader {
        SharedAppFlagReader(args: SharedAppFlags.jiraArgs, flag: SharedAppFlags.jiraFlag)
    }

    func read(cliPath: String?) async {
        reads += 1
        let read = reads
        guard let cliPath else { return }
        // A failed run is logged by the runner; an answer that is not the rows is logged here.
        guard let data = try? await ProcessCLIRunner(binaryPath: cliPath).run(args: args) else { return }
        let ids: Set<Int>
        do {
            ids = try SharedAppFlags.accountIDs(data, flag: flag)
        } catch {
            CLILog.failure(args: args, exitCode: 0, stderr: "stdout is not the account rows (\(data.count) bytes)")
            return
        }
        guard read > applied else { return }
        applied = read
        accountIDs = ids
    }
}
