/// The relay's zone names (relay `proto/README.md` "Zone names"). The phone reads its Mac's data
/// zone and reads and writes its own mailbox with that Mac (R4); pairing zones come with Phase 3.
public enum HostedRelayZones {
    /// The Mac's published slices: `data/<mac>`.
    public static func data(mac: String) -> String {
        "data/\(mac)"
    }

    /// One phone's mailbox with one Mac: `relay/<mac>/<phone>`.
    public static func mailbox(mac: String, phone: String) -> String {
        "relay/\(mac)/\(phone)"
    }

    /// A pairing slot's zone: `pair/<slot>` (Phase 3).
    public static func pair(slot: String) -> String {
        "pair/\(slot)"
    }
}
