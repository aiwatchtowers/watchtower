import AppKit
import CloudKit
import Foundation
import WatchtowerSync

/// Silent pushes to the bridge become `Event{pull_now}` for the hub (Go hub spec §6.2), which then reads its
/// mailboxes at once. The bridge registers two subscriptions in the private database once the hub said Hello:
/// a database subscription that sends a silent push on any change (what CKSyncEngine set up for the Swift
/// hub), and the Kit's `AskAlertSubscription` query subscription on `sig-` records — the only signal work the
/// bridge does; signals themselves reach it as ordinary saves and deletes.
public final class PushReceiver: @unchecked Sendable {
    private let emit: @Sendable (BridgeEvent) -> Void

    public init(emit: @escaping @Sendable (BridgeEvent) -> Void) {
        self.emit = emit
    }

    /// A remote notification reached the app: whatever changed, the hub reads now. Its content is not read
    /// (a CloudKit push carries ids only, and the hub reads everything through the bridge anyway).
    public func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        emit(BridgeEvent(pullNow: true))
    }

    /// The database subscription's id for one hub.
    public static func databaseSubscriptionID(hubID: String) -> String { "bridge-db-\(hubID)" }

    /// The subscriptions the bridge keeps for `hubID`.
    public static func subscriptions(hubID: String) -> [CKSubscription] {
        let database = CKDatabaseSubscription(subscriptionID: databaseSubscriptionID(hubID: hubID))
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        database.notificationInfo = info
        return [database] + [AskAlertSubscription.subscription(for: .private, hubID: hubID)].compactMap { $0 }
    }

    /// Saves the subscriptions (re-saving one replaces it); a failure is logged by class and retried at the
    /// next launch.
    public static func register(hubID: String, saver: any SubscriptionSaving) async {
        for subscription in subscriptions(hubID: hubID) {
            do {
                try await saver.save(subscription)
            } catch {
                bridgeLogger.notice("subscription save failed: \(bridgeFailureClass(error), privacy: .public)")
            }
        }
    }
}

// MARK: - The app

/// The bridge app's arguments: `--socket <hub dir>/bridge.sock`.
public struct BridgeArguments: Equatable, Sendable {
    public let socketPath: String

    public init?(_ arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--socket"), arguments.indices.contains(flag + 1) else { return nil }
        let path = arguments[flag + 1]
        guard path.hasPrefix("/") else { return nil }
        socketPath = path
    }

    public var hubDir: URL { URL(fileURLWithPath: socketPath).deletingLastPathComponent() }
}

/// The `LSUIElement` app around the bridge: no Dock icon, no window. It refuses a hub dir that is not this
/// user's private (0700) directory, serves the socket, registers for remote notifications, and exits when the
/// daemon has been gone 60 s.
@MainActor
public final class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    private let arguments: BridgeArguments
    private var server: BridgeSocketServer?
    private var push: PushReceiver?

    public init(arguments: BridgeArguments) {
        self.arguments = arguments
    }

    /// The hub dir is this user's and closed to everyone else.
    static func hubDirIsPrivate(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
        return st.st_uid == geteuid() && st.st_mode & 0o077 == 0
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let hubDir = arguments.hubDir
        guard Self.hubDirIsPrivate(hubDir) else {
            bridgeLogger.error("hub dir is not a private directory of this user; exiting")
            exit(2)
        }
        let tags: BridgeTagMap
        do {
            tags = try BridgeTagMap(directory: hubDir.appendingPathComponent("cloudkit"))
        } catch {
            bridgeLogger.error("bridge.db could not be opened; exiting")
            exit(3)
        }
        let stash = hubDir.appendingPathComponent("cloudkit").appendingPathComponent("stash")
        let entitled = CloudKitTransport.entitlementPresent()
        let service = BridgeService(
            tags: tags, hubDir: hubDir,
            makeBackends: { hubID in
                BridgeService.Backends(
                    cloud: CloudKitBridgeCloud(hubID: hubID, stashDirectory: stash),
                    shares: CloudKitZoneShares(hubID: hubID))
            },
            onHello: { hubID in
                guard entitled else { return }
                Task { await PushReceiver.register(hubID: hubID, saver: CloudKitSubscriptionSaver()) }
            })
        let server = BridgeSocketServer(socketPath: arguments.socketPath, service: service) {
            bridgeLogger.notice("no daemon connection for 60 s; exiting")
            exit(0)
        }
        do {
            try server.start()
        } catch {
            bridgeLogger.error("bridge socket could not be served; exiting")
            exit(4)
        }
        self.server = server
        push = PushReceiver { [weak server] event in server?.broadcast(event) }
        if entitled { NSApplication.shared.registerForRemoteNotifications() }
    }

    public func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        push?.didReceiveRemoteNotification(userInfo)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }
}
