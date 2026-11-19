import Foundation
import WatchtowerCore

/// Which Google or Jira accounts Go reports on a retiring shared app
/// (`google accounts --json` `shared_gmail`, `jira accounts --json`
/// `shared_atlassian`, #1887 T19): the banners of company screens spec §7
/// and the rows' **Shared app** tag; for Google also which accounts run on
/// the person's own project (`own_project`, C4: the own-project group and
/// its policy lock). Go owns the client resolver that decides them; this
/// only reads the flags.
///
/// Empty before the first successful read, so a failed one shows no banner;
/// a later failure keeps the last answer (logged, never shown: the detail
/// works without it). Reads finish out of order: only a newer read's answer
/// replaces the ids.
@MainActor
@Observable
final class SharedAppFlagReader {
    private var flagged: [String: Set<Int>] = [:]
    @ObservationIgnored private let args: [String]
    @ObservationIgnored private let flag: String
    @ObservationIgnored private let flags: [String]
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var applied = 0

    /// `flag` is the shared-app flag; `extraFlags` are read alongside it.
    init(args: [String], flag: String, extraFlags: [String] = []) {
        self.args = args
        self.flag = flag
        flags = [flag] + extraFlags
    }

    static func google() -> SharedAppFlagReader {
        SharedAppFlagReader(args: SharedAppFlags.googleArgs, flag: SharedAppFlags.googleFlag,
                            extraFlags: [SharedAppFlags.ownProjectFlag])
    }

    static func jira() -> SharedAppFlagReader {
        SharedAppFlagReader(args: SharedAppFlags.jiraArgs, flag: SharedAppFlags.jiraFlag)
    }

    /// The accounts on the retiring shared app.
    var accountIDs: Set<Int> { flagged[flag] ?? [] }

    /// Google: the accounts on the person's own project.
    var ownProjectIDs: Set<Int> { flagged[SharedAppFlags.ownProjectFlag] ?? [] }

    func read(cliPath: String?) async {
        reads += 1
        let read = reads
        guard let cliPath else { return }
        // A failed run is logged by the runner; an answer that is not the rows is logged here.
        guard let data = try? await ProcessCLIRunner(binaryPath: cliPath).run(args: args) else { return }
        let ids: [String: Set<Int>]
        do {
            ids = try SharedAppFlags.accountIDs(data, flags: flags)
        } catch {
            CLILog.failure(args: args, exitCode: 0, stderr: "stdout is not the account rows (\(data.count) bytes)")
            return
        }
        guard read > applied else { return }
        applied = read
        flagged = ids
    }
}
