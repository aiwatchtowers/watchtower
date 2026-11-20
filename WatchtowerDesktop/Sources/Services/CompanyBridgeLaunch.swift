import Foundation
import WatchtowerCore

/// The corp build's move onto a company bundle (#1887 T11a, spec §5): the app
/// runs `watchtower company bridge --json`, which stores the build's baked
/// clients as the company's bundle, gives every account on them its client
/// record, ties the ones the bundle covers and writes
/// `<workspace>/company_migrated` last. It runs at launch (after the
/// migration, before the daemon starts) and again right before a public
/// update is installed, so an account signed in since the launch is covered —
/// each time once per workspace with a database (`--workspace`), since an
/// update replaces the app for all of them. Only once every workspace carries
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

    /// The launch's migration step: `db migrate`, then the bridge (it needs
    /// the company columns). Both run inside the launch's daemon-start gate
    /// (`migrateCompactOpen`), so the launch's daemon starts on the tied
    /// accounts; a daemon still running from before resolves the same baked
    /// client either way — a tie never changes an account's client.
    nonisolated static func migrateThenBridge(
        migrate: () -> Void = { DatabaseManager.runCLIMigrations() },
        bridge: () -> Void = { _ = run() }
    ) {
        migrate()
        bridge()
    }

    /// `DatabaseManager.runCLILaunchStep`'s shape: arguments, label, CLI
    /// path, report; true when the step exited 0.
    typealias LaunchStep = (_ arguments: [String], _ label: String, _ cliPath: String?,
                            _ report: @escaping @Sendable (String) -> Void) -> Bool

    /// Runs the bridge on a corp build, once for every workspace under
    /// `basePath` with a database, through `step` (the launch step runner;
    /// tests replace it). Each run blocks for up to 30 s, so call it off the
    /// main actor and off the concurrency pool. A workspace that fails does not
    /// stop the others; its marker stays missing and the next run retries it.
    /// True when the build does not bridge or every run succeeded.
    @discardableResult
    nonisolated static func run(
        flavor: String = bundleFlavor,
        basePath: String = Constants.databasePath,
        cliPath: @autoclosure () -> String? = Constants.findCLIPath(),
        report: @escaping @Sendable (String) -> Void = { NSLog("[Watchtower] %@", $0) },
        step: LaunchStep = { DatabaseManager.runCLILaunchStep($0, label: $1, cliPath: $2, report: $3) }
    ) -> Bool {
        guard applies(flavor: flavor) else { return true }
        let path = cliPath()
        var allBridged = true
        for name in Constants.workspacesWithDatabase(under: basePath) {
            // `--workspace` only picks the database for this run; the CLI
            // never writes it back as the active workspace.
            let bridged = step(["company", "bridge", "--json", "--workspace", name],
                               "Company bridge (\(name))", path, report)
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
