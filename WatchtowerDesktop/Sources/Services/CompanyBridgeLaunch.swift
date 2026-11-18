import Foundation
import WatchtowerCore

/// The corp build's move onto a company bundle (#1887 T11a, spec §5): the app
/// runs `watchtower company bridge --json`, which stores the build's baked
/// clients as the company's bundle, gives every account on them its client
/// record, ties the ones the bundle covers and writes
/// `<workspace>/company_migrated` last. It runs at launch (after the
/// migration, before the daemon starts) and again right before a public
/// update is installed, so an account signed in since the launch is covered.
/// Only once every workspace carries the marker does UpdateService let the
/// flavored build take the public feed. Go owns every write; a failure is
/// logged and retried at the next run.
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

    /// Runs the bridge on a corp build; blocks for up to 30 s, so call it
    /// off the main actor and off the concurrency pool. True when the build
    /// does not bridge or the bridge succeeded.
    @discardableResult
    nonisolated static func run(
        flavor: String = bundleFlavor,
        cliPath: @autoclosure () -> String? = Constants.findCLIPath(),
        report: @escaping @Sendable (String) -> Void = { NSLog("[Watchtower] %@", $0) }
    ) -> Bool {
        guard applies(flavor: flavor) else { return true }
        return DatabaseManager.runCLILaunchStep(
            ["company", "bridge", "--json"], label: "Company bridge", cliPath: cliPath(), report: report
        )
    }

    /// Whether every workspace with a database carries the marker: an update
    /// replaces the app for all of them, and the bridge only ever runs on the
    /// active one. No workspace at all is not migrated.
    nonisolated static func workspacesMigrated(basePath: String = Constants.databasePath) -> Bool {
        let workspaces = Constants.workspacesWithDatabase(under: basePath)
        return !workspaces.isEmpty && workspaces.allSatisfy { name in
            FileManager.default.fileExists(atPath: "\(basePath)/\(name)/\(markerName)")
        }
    }
}
