import Foundation

/// The RC §10 indicators of Settings → Mobile (go hub plan 4 Task 8,
/// mockups `docs/design/mockups/go-hub/index.html` §18–§21): the hub's Relay
/// lines from `hub status` `relay`, and each phone's lines from `hub phones`.
/// Every line is one fact; any of them can show beside the others. Each
/// builder returns the line with its tone (`HubLine`).
extension MobileSettingsModel {
    // MARK: Hub

    nonisolated static let relayRowTitle = "Relay"
    nonisolated static let relayConnecting = "Connecting to Relay…"
    nonisolated static let relayPushOff = "Relay has no notifications configured."
    nonisolated static let hubQuotaFull = "This Mac's Relay storage is full (5 GB). "
        + "New changes are not sent until older recordings are removed."

    /// "Connected · last change delivered <age> ago"; just "Connected" before
    /// the first save since the hub started.
    nonisolated static func relayConnectedLine(lastSavedAt: Date?, now: Date) -> String {
        guard let lastSavedAt else { return "Connected" }
        return "Connected · last change delivered \(ageText(now.timeIntervalSince(lastSavedAt))) ago"
    }

    /// "Relay unavailable for <N> min. …", N the whole minutes since it
    /// became unavailable (at least 1).
    nonisolated static func relayUnavailableLine(since: Date, now: Date) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(since) / 60))
        return "Relay unavailable for \(minutes) min. Phones keep their changes and send them when it is back."
    }

    /// An age as the connected line says it. The hub rounds the last save
    /// down to the minute, so nothing finer than a minute is said.
    nonisolated static func ageText(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h" }
        return "\(hours / 24) d"
    }

    /// The connection line for `relay.state`; nil for a state this version
    /// does not know and for a `since` that did not read as a time.
    nonisolated static func relayConnection(_ relay: MobileHubCLI.RelayHealth, now: Date) -> HubLine? {
        guard let since = relay.since else { return nil }
        return switch relay.state {
        case "connected": HubLine(text: relayConnectedLine(lastSavedAt: relay.lastSavedAt, now: now), tone: .neutral)
        case "connecting": HubLine(text: relayConnecting, tone: .neutral)
        case "unavailable": HubLine(text: relayUnavailableLine(since: since, now: now), tone: .warning)
        default: nil
        }
    }

    /// The hub's Relay lines in their order: connection, notifications, storage.
    nonisolated static func relayLines(_ relay: MobileHubCLI.RelayHealth?, now: Date) -> [HubLine] {
        guard let relay else { return [] }
        return [
            relayConnection(relay, now: now),
            relay.pushOff ? HubLine(text: relayPushOff, tone: .warning) : nil,
            relay.quotaHub ? HubLine(text: hubQuotaFull, tone: .error) : nil
        ].compactMap { $0 }
    }

    // MARK: Phones

    nonisolated static let noTokenLine = "Notifications aren't set up on this iPhone. Open Watchtower on it once."
    nonisolated static let alertAcceptedLine = "Last alert: sent to relay"

    /// A phone without a subscription on a hub that runs over Relay.
    nonisolated static func updatesLine(name: String) -> HubLine {
        HubLine(
            text: "Doesn't get updates: this Mac runs over Relay. Switch this Mac to iCloud from a subscribed phone, "
                + "or subscribe on \(name).",
            tone: .warning
        )
    }

    /// What this Mac's side holds of the phone's actions (never the phone's
    /// own queue); nil for none.
    nonisolated static func undeliveredLine(_ count: Int) -> HubLine? {
        let text: String? = switch count {
        case ..<1: nil
        case 1: "On this Mac's side, 1 action from this phone is not applied yet."
        default: "On this Mac's side, \(count) actions from this phone are not applied yet."
        }
        return text.map { HubLine(text: $0, tone: .warning) }
    }

    nonisolated static func mailboxLine(name: String) -> HubLine {
        HubLine(text: "\(name)'s Relay mailbox is full.", tone: .error)
    }

    /// The last alert push's outcome class as the row says it; nil for none
    /// and for the classes the row does not name.
    nonisolated static func alertsLine(_ outcome: String) -> HubLine? {
        switch outcome {
        case "no_token": HubLine(text: noTokenLine, tone: .warning)
        case "accepted": HubLine(text: alertAcceptedLine, tone: .neutral)
        default: nil
        }
    }

    /// A phone's row with its four lines from `hub phones`, each nil when its
    /// key is null (not known). The updates line needs a hub on Relay and
    /// `paying` false (never null); a phone without a subscription shows no
    /// "Last alert: …".
    nonisolated static func withIndicators(_ row: PhoneRow, _ phone: MobileHubCLI.Phone, hubTransport: String?) -> PhoneRow {
        var row = row
        let free = phone.paying == false
        row.updatesLine = free && hubTransport == "relay" ? updatesLine(name: phone.name) : nil
        row.undeliveredLine = phone.undelivered.flatMap(undeliveredLine)
        row.mailboxLine = phone.mailboxFull == true ? mailboxLine(name: phone.name) : nil
        row.alertsLine = free ? nil : phone.alerts.flatMap(alertsLine)
        return row
    }
}

extension MobileSettingsModel.PhoneRow {
    /// The row's indicator lines in their order, the unknown and absent ones left out.
    var indicatorLines: [MobileSettingsModel.HubLine] {
        [mailboxLine, updatesLine, undeliveredLine, alertsLine].compactMap { $0 }
    }
}
