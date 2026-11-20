import Foundation
import WatchtowerCore

/// The corp build's move onto a company bundle (#1887 T11a, spec §5): the app
/// runs `watchtower company bridge --json`, which stores the build's baked
/// clients as the company's bundle, gives every account on them its client
/// record, ties the ones the bundle covers and writes
/// `<workspace>/company_migrated` last. The launch bridges the active
/// workspace after the migration, before the daemon starts
/// (`migrateThenBridge`), and every other workspace with a database once the
/// database is open, in the background (`runOthers`): an update replaces the
/// app for all of them, so each needs its marker. Right before a public
/// update is installed it bridges them all again (`runAll`), so an account
/// signed in since the launch is covered. Only once every workspace carries
/// the marker does UpdateService let the flavored build take the public feed.
/// Go owns every write; a failure is logged and retried at the next run.
enum CompanyBridgeLaunch {
    /// The marker `company bridge` writes into the workspace once it is done.
    nonisolated static let markerName = "company_migrated"

    /// Whether a build of this flavor bridges: a flavored build other than
    /// dev (the corp build). The public and dev builds never run it.
    nonisolated static func applies(flavor: String) -> Bool {
        !flavor.isEmpty && flavor != "dev"
    }

    /// The build flavor stamped into Info.plist by build-app.sh (absent on
    /// default builds).
    nonisolated static var bundleFlavor: String {
        (Bundle.main.object(forInfoDictionaryKey: "WTBuildFlavor") as? String) ?? ""
    }

    /// One CLI run: arguments, the label it is logged under, the time limit
    /// in seconds; true when it exited 0. Tests replace it.
    typealias LaunchStep = (_ arguments: [String], _ label: String, _ timeout: Int) -> Bool

    /// The active workspace's run sits on the launch path, so it keeps the
    /// launch steps' 30 s. Another workspace's runs are off it, and its
    /// database is migrated only by the bridge's own open (`db.Open`), so a
    /// long migration backlog gets room to finish instead of being killed —
    /// and rolled back — at every launch.
    nonisolated static let activeTimeout = 30
    nonisolated static let otherTimeout = 300

    /// The real runner: the installed CLI under `runCLILaunchStep`.
    nonisolated static func launchStep(
        cliPath: @escaping @autoclosure () -> String? = Constants.findCLIPath(),
        report: @escaping @Sendable (String) -> Void = { NSLog("[Watchtower] %@", $0) }
    ) -> LaunchStep {
        { DatabaseManager.runCLILaunchStep($0, label: $1, cliPath: cliPath(), timeout: $2, report: report) }
    }

    /// The launch's migration step: `db migrate`, then the active workspace's
    /// bridge (it needs the company columns). Both run inside the launch's
    /// daemon-start gate (`migrateCompactOpen`), so the launch's daemon starts
    /// on the tied accounts; a daemon still running from before resolves the
    /// same baked client either way — a tie never changes an account's client.
    nonisolated static func migrateThenBridge(
        migrate: () -> Void = { DatabaseManager.runCLIMigrations() },
        bridge: () -> Void = { _ = runActive() }
    ) {
        migrate()
        bridge()
    }

    /// Bridges the active workspace (the CLI resolves it, as every launch
    /// step does) on a corp build; blocks for up to 30 s, so call it off the
    /// main actor and off the concurrency pool. True when the build does not
    /// bridge or the bridge succeeded.
    @discardableResult
    nonisolated static func runActive(flavor: String = bundleFlavor, step: LaunchStep = launchStep()) -> Bool {
        guard applies(flavor: flavor) else { return true }
        return step(["company", "bridge", "--json"], "Company bridge", activeTimeout)
    }

    /// Bridges every workspace under `basePath` with a database except
    /// `active` (the launch already did it), each up to 300 s; for after the
    /// launch's database open, off the main actor and the concurrency pool.
    @discardableResult
    nonisolated static func runOthers(
        than active: String,
        flavor: String = bundleFlavor,
        basePath: String = Constants.databasePath,
        step: LaunchStep = launchStep()
    ) -> Bool {
        guard applies(flavor: flavor) else { return true }
        return bridge(Constants.workspacesWithDatabase(under: basePath).filter { $0 != active }, step: step)
    }

    /// Bridges every workspace under `basePath` with a database, each up to
    /// 300 s: the run before a public update is installed. True when the
    /// build does not bridge or every run succeeded.
    @discardableResult
    nonisolated static func runAll(
        flavor: String = bundleFlavor,
        basePath: String = Constants.databasePath,
        step: LaunchStep = launchStep()
    ) -> Bool {
        guard applies(flavor: flavor) else { return true }
        return bridge(Constants.workspacesWithDatabase(under: basePath), step: step)
    }

    /// One `company bridge --workspace <name>` per workspace. A workspace
    /// that fails does not stop the others; its marker stays missing and the
    /// next run retries it. `--workspace` only picks the database for that
    /// run; the CLI never writes it back as the active workspace.
    nonisolated private static func bridge(_ workspaces: [String], step: LaunchStep) -> Bool {
        var allBridged = true
        for name in workspaces {
            let bridged = step(["company", "bridge", "--json", "--workspace", name],
                               "Company bridge (\(name))", otherTimeout)
            allBridged = allBridged && bridged
        }
        return allBridged
    }

    /// Whether every workspace with a database carries the marker: an update
    /// replaces the app for all of them. No workspace at all is not migrated.
    nonisolated static func workspacesMigrated(basePath: String = Constants.databasePath) -> Bool {
        let workspaces = Constants.workspacesWithDatabase(under: basePath)
        return !workspaces.isEmpty && workspaces.allSatisfy { name in
            FileManager.default.fileExists(atPath: "\(basePath)/\(name)/\(markerName)")
        }
    }
}
