import CryptoKit
import Foundation
import os
import WatchtowerHostedRelay

/// Tells the relay this phone's APNs token (`register_push`): the Mac's silent pushes and alerts reach the phone by it.
///
/// Sends when a token is known, this phone already holds a `relay_auth` key (`hasIdentity`, which never creates one:
/// the identity comes with the first use of the relay), the build names its APNs environment, the app has been active
/// in this process, and this process has not sent this token yet. So once per launch, and again on a token change. The
/// token lives in memory only: iOS gives it at each launch's `registerForRemoteNotifications`.
///
/// A launch into the background (a push) sends nothing until its first `foreground()`, as the account center's first
/// pass waits for it: a process iOS never brings forward leaves the relay with the token the last open sent. A failure
/// stays owed, for the next `reachable()` or `foreground()`, one that landed during the send included; there is no timer.
///
/// Built only while the relay is available (`AppRoot.wireRelayPush`): with an empty origin nothing here exists.
@MainActor
final class RelayPushRegistrar {
    enum State: Equatable {
        case idle
        /// The relay took the token with this hash (`hash`). Never the token itself.
        case sent(tokenHash: String)
        case failed
    }

    private(set) var state = State.idle
    /// The send running; nil once it ended. A test awaits it.
    private(set) var sending: Task<Void, Never>?

    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "RelayPush")

    private let availability: RelayAvailability
    private let environment: RelayPushEnvironment?
    private let hasIdentity: () -> Bool
    private let send: (String, RelayPushEnvironment) async throws -> Void
    /// The token, as hex.
    private var token: String?
    private var sentToken: String?
    /// The app has been active in this process.
    private var foregrounded = false
    /// A `reachable()` or `foreground()` landed during the running send: if it fails, it retries once it ends.
    private var eventDuringSend = false

    init(
        availability: RelayAvailability,
        environment: RelayPushEnvironment?,
        hasIdentity: @escaping () -> Bool,
        send: @escaping (String, RelayPushEnvironment) async throws -> Void
    ) {
        self.availability = availability
        self.environment = environment
        self.hasIdentity = hasIdentity
        self.send = send
    }

    /// The registrar on the process's one relay session. The session is built only by a send, which needs an identity.
    static func live(relay: SharedRelaySession, environment: RelayPushEnvironment?) -> RelayPushRegistrar {
        RelayPushRegistrar(
            availability: relay.availability,
            environment: environment,
            hasIdentity: { (try? relay.hasIdentity()) == true },
            send: { token, environment in
                guard let account = try relay.account() else { throw HostedRelayPairing.Refusal.unreachable }
                try await account.registerPush(token: token, environment: environment)
            }
        )
    }

    func tokenArrived(_ token: Data) {
        self.token = token.map { String(format: "%02x", $0) }.joined()
        sendIfOwed()
    }

    /// The account center's first `accountID`, a finished relay link, an upgrade's first step.
    func identityMayExist() {
        sendIfOwed()
    }

    /// `.reachable(true)`, forwarded by the account center (the one reader of the session's events).
    func reachable() {
        eventDuringSend = sending != nil
        sendIfOwed()
    }

    func foreground() {
        foregrounded = true
        eventDuringSend = sending != nil
        sendIfOwed()
    }

    private func sendIfOwed() {
        guard case .available = availability, foregrounded, sending == nil, let token, token != sentToken,
              let environment, hasIdentity() else { return }
        sending = Task {
            do {
                try await send(token, environment)
                sentToken = token
                state = .sent(tokenHash: Self.hash(token))
            } catch {
                state = .failed
                Self.logger.error("\(Self.failureLog(error), privacy: .public)")
            }
            sending = nil
            // A token that changed during the send, or an event that landed in it; else a failure waits for the next event.
            let retry = eventDuringSend || self.token != token
            eventDuringSend = false
            if retry { sendIfOwed() }
        }
    }

    nonisolated static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The error's type only: never the token or the relay's message.
    nonisolated static func failureLog(_ error: any Error) -> String {
        "register_push failed: \(String(describing: type(of: error)))"
    }

    /// `didFailToRegisterForRemoteNotifications`: Desktop then shows the hub's "not set up" line from `no_token`.
    nonisolated static func registrationFailureLog(_ error: any Error) -> String {
        "APNs registration failed: code \((error as NSError).code)"
    }

    nonisolated static func logRegistrationFailure(_ error: any Error) {
        logger.error("\(registrationFailureLog(error), privacy: .public)")
    }
}
