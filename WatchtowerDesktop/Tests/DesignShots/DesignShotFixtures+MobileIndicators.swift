import Foundation
@testable import WatchtowerDesktop

/// The RC §10 indicator shots of Settings → Mobile (go hub plan 4 Task 8,
/// coverage table rows 5–25, mockups `docs/design/mockups/go-hub/index.html`
/// §19–§21), on fixture data (Phone A / Phone B): one `hub status` and one
/// `hub phones` read per frame.
@MainActor
extension MobileSettingsShotFixtures {
    typealias Relay = MobileHubCLI.RelayHealth
    typealias Phone = MobileHubCLI.Phone

    /// The hub's status and its phones for an indicator frame.
    static func indicators(_ frame: Frame) -> (MobileHubCLI.Status, [Phone]) {
        if let relay = hubRelay(frame) {
            let only = frame == .bothQuotas
                ? phone("AAAA0001", "Phone A", mailboxFull: true, alerts: "accepted")
                : phone("AAAA0001", "Phone A", alerts: "accepted")
            return (running(relay: relay), [only])
        }
        return (running(relay: frame == .indicatorsNarrow ? allHubLines : connectedRelay), phones(frame))
    }

    /// The hub frames' relay block (one subscribed phone beside it); nil for the phone frames.
    private static func hubRelay(_ frame: Frame) -> Relay? {
        let connecting = now.addingTimeInterval(-20)
        let unavailable = now.addingTimeInterval(-150)
        switch frame {
        case .relayConnected: return connectedRelay
        case .relayConnecting: return Relay(state: "connecting", since: connecting)
        case .relayUnavailable: return Relay(state: "unavailable", since: unavailable)
        case .connectedPushOff: return relay(pushOff: true)
        case .connectedQuotaHub, .bothQuotas: return relay(quotaHub: true)
        case .connectingPushOff: return Relay(state: "connecting", since: connecting, pushOff: true)
        case .unavailablePushOff: return Relay(state: "unavailable", since: unavailable, pushOff: true)
        case .hubAllLines: return allHubLines
        default: return nil
        }
    }

    /// The phone frames' phones (the hub connected, or every hub line when narrow).
    private static func phones(_ frame: Frame) -> [Phone] {
        switch frame {
        case .alertAccepted:
            return [phone("AAAA0001", "Phone A", alerts: "accepted")]
        case .mailboxFull:
            return [phone("AAAA0001", "Phone A", mailboxFull: true, alerts: "accepted"), phone("BBBB0002", "Phone B", alerts: "accepted")]
        case .freePhoneOnRelay:
            return [phone("AAAA0001", "Phone A", alerts: "accepted"), phone("BBBB0002", "Phone B", paying: false, alerts: "accepted")]
        case .undeliveredOne:
            return [phone("AAAA0001", "Phone A", undelivered: 1, alerts: "accepted")]
        case .undeliveredMany:
            return [phone("AAAA0001", "Phone A", undelivered: 3, alerts: "accepted")]
        case .notificationsMissing:
            return [phone("AAAA0001", "Phone A", alerts: "no_token")]
        case .phoneAllLines:
            // A free phone: its last alert is not shown.
            return [phone("BBBB0002", "Phone B", paying: false, undelivered: 3, alerts: "accepted")]
        case .undeliveredNoToken:
            return [phone("AAAA0001", "Phone A", undelivered: 1, alerts: "no_token")]
        case .twoMailboxesFull:
            return [
                phone("AAAA0001", "Phone A", mailboxFull: true, alerts: "accepted"),
                phone("BBBB0002", "Phone B", mailboxFull: true, alerts: "accepted")
            ]
        case .indicatorsNarrow:
            return [
                phone("AAAA0001", "Phone A", mailboxFull: true, alerts: "accepted"),
                phone("BBBB0002", "Phone B", paying: false, undelivered: 3, mailboxFull: true, alerts: "accepted")
            ]
        default:
            return []
        }
    }

    private static var allHubLines: Relay {
        Relay(state: "unavailable", since: now.addingTimeInterval(-150), quotaHub: true, pushOff: true)
    }

    private static func relay(quotaHub: Bool = false, pushOff: Bool = false) -> Relay {
        Relay(state: "connected", since: connectedRelay.since, quotaHub: quotaHub, pushOff: pushOff, lastSavedAt: connectedRelay.lastSavedAt)
    }

    private static func phone(
        _ id: String, _ name: String, paying: Bool = true, undelivered: Int = 0, mailboxFull: Bool = false, alerts: String = ""
    ) -> Phone {
        Phone(
            deviceID: id, name: name, scope: "shared", linkedAt: now.addingTimeInterval(-21 * 86_400),
            typingAllowed: true, typingRequested: false, permissionsAllowed: true, permissionsRequested: false,
            startSessionsAllowed: true, startSessionsGranted: true, transport: "relay",
            paying: paying, undelivered: undelivered, mailboxFull: mailboxFull, alerts: alerts
        )
    }
}
