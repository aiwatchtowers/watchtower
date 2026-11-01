import AppKit
import CloudKit
import Foundation
import WatchtowerSync

/// Silent pushes to the bridge become `Event{pull_now}` for the hub (Go hub spec §6.2), which then reads its
/// mailboxes at once. The Swift hub got its silent pushes from CKSyncEngine's own database subscription
/// (`TrayAppDelegate.application(_:didReceiveRemoteNotification:)` → `wakeRelay`); the bridge, with no engine,
/// saves one database subscription of its own (`databaseSubscriptionID`) once the hub said Hello. It never
/// saves or deletes any other subscription: the ask-alert query subscription on `sig-` records
/// (`AskAlertSubscription`, `ask-alert-<hub_id>`) belongs to the phone, which registers it for its
/// notification extension. Signals reach the bridge as ordinary saves and deletes.
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

    /// Turns every `CKAccountChanged` posted on `center` into `Event{account_changed}`: the hub drops what
    /// names the old user and closes an open link code. The token keeps the observation; drop it to stop.
    public func observeAccountChanges(on center: NotificationCenter = .default) -> NSObjectProtocol {
        let emit = emit
        return center.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in
            emit(BridgeEvent(accountChanged: true))
        }
    }

    /// The bridge's own database subscription id for one hub.
    public static func databaseSubscriptionID(hubID: String) -> String { "watchtower-bridge-db-\(hubID)" }

    /// The phone's ask-alert subscription id, which the bridge must never touch.
    public static func phoneAlertSubscriptionID(hubID: String) -> String { AskAlertSubscription.subscriptionID(hubID: hubID) }

    /// The one subscription the bridge keeps for `hubID`: silent pushes on any change of the private database.
    public static func subscription(hubID: String) -> CKSubscription {
        let database = CKDatabaseSubscription(subscriptionID: databaseSubscriptionID(hubID: hubID))
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        database.notificationInfo = info
        return database
    }

    /// Saves the bridge's subscription through `save` (re-saving it replaces it); a failure is logged by class
    /// and retried at the next launch.
    public static func register(hubID: String, save: @Sendable (CKSubscription) async throws -> Void) async {
        do {
            try await save(subscription(hubID: hubID))
        } catch {
            bridgeLogger.notice("subscription save failed: \(bridgeFailureClass(error), privacy: .public)")
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
/// daemon has been gone 10 minutes.
@MainActor
public final class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    private let arguments: BridgeArguments
    private var server: BridgeSocketServer?
    private var push: PushReceiver?
    private var accountObservation: NSObjectProtocol?

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
        let entitled = CloudKitTransport.entitlementPresent()
        let service = BridgeService(
            tags: tags, hubDir: hubDir,
            makeBackends: { hubID in
                BridgeService.Backends(
                    cloud: CloudKitBridgeCloud(hubID: hubID),
                    shares: CloudKitZoneShares(hubID: hubID))
            },
            onHello: { hubID in
                guard entitled else { return }
                let saver = CloudKitSubscriptionSaver()
                Task { await PushReceiver.register(hubID: hubID) { try await saver.save($0) } }
            })
        let server = BridgeSocketServer(socketPath: arguments.socketPath, service: service) {
            bridgeLogger.notice("no daemon connection for 10 min; exiting")
            exit(0)
        }
        do {
            try server.start()
        } catch {
            bridgeLogger.error("bridge socket could not be served; exiting")
            exit(4)
        }
        self.server = server
        let push = PushReceiver { [weak server] event in server?.broadcast(event) }
        self.push = push
        accountObservation = push.observeAccountChanges()
        if entitled { NSApplication.shared.registerForRemoteNotifications() }
    }

    public func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        push?.didReceiveRemoteNotification(userInfo)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }
}
