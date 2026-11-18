import Foundation
import WatchtowerCore

/// The corp build's move onto a company bundle (#1887 T11a, spec §5): at
/// launch, after the migration and before the daemon starts, the app runs
/// `watchtower company bridge --json`, which stores the build's baked clients
/// as the company's bundle, ties the accounts signed in through them and
/// writes `<workspace>/company_migrated` last. Only then does UpdateService
/// let the flavored build take the public feed. Go owns every write; a
/// failure is logged and retried at the next launch.
enum CompanyBridgeLaunch {
    /// The marker `company bridge` writes into the workspace once it is done.
    nonisolated static let markerName = "company_migrated"

    /// Whether a build of this flavor bridges: a flavored build other than
    /// dev (the corp build). The public and dev builds never run it.
    nonisolated static func applies(flavor: String) -> Bool {
        !flavor.isEmpty && flavor != "dev"
    }

    /// The build flavor stamped into Info.plist by build-app.sh.
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
        bridge: () -> Void = { run() }
    ) {
        migrate()
        bridge()
    }

    /// Runs the bridge on a corp build; blocks for up to 30 s, so call it
    /// off the main actor and off the concurrency pool.
    nonisolated static func run(
        flavor: String = bundleFlavor,
        cliPath: @autoclosure () -> String? = Constants.findCLIPath(),
        report: @escaping @Sendable (String) -> Void = { NSLog("[Watchtower] %@", $0) }
    ) {
        guard applies(flavor: flavor) else { return }
        DatabaseManager.runCLILaunchStep(
            ["company", "bridge", "--json"], label: "Company bridge", cliPath: cliPath(), report: report
        )
    }

    /// Whether the active workspace carries the marker. No workspace (or an
    /// unreadable config) is not migrated.
    nonisolated static func workspaceMigrated() -> Bool {
        guard let dbPath = try? DatabaseManager.resolveDBPath() else { return false }
        let workspace = (dbPath as NSString).deletingLastPathComponent
        return FileManager.default.fileExists(atPath: (workspace as NSString).appendingPathComponent(markerName))
    }
}
