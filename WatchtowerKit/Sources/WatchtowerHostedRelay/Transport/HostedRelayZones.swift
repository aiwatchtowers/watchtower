/// The relay's zone names (relay `proto/README.md` "Zone names"). The phone reads its Mac's data
/// zone and reads and writes its own mailbox with that Mac (R4); while it links, both lanes are
/// the pairing slot's zone (R3 of Phase 3).
public enum HostedRelayZones {
    /// The Mac's published slices: `data/<mac>`.
    public static func data(mac: String) -> String {
        "data/\(mac)"
    }

    /// One phone's mailbox with one Mac: `relay/<mac>/<phone>`.
    public static func mailbox(mac: String, phone: String) -> String {
        "relay/\(mac)/\(phone)"
    }

    /// A pairing slot's zone: `pair/<slot>`.
    public static func pair(slot: String) -> String {
        "pair/\(slot)"
    }
}

/// Which relay zones a `HostedRelayTransport` serves (R3 of Phase 3).
public enum HostedRelayTransportMode: Equatable, Sendable {
    /// `.data` is the Mac's data zone, `.relay` the phone's mailbox with it.
    case hub
    /// Linking: `.data` and `.relay` are both `pair/<slot>`. The phone writes only its hello
    /// (relay lane) and reads the Mac's keybox (data lane); no attachments.
    case pairing(slot: String)
}
