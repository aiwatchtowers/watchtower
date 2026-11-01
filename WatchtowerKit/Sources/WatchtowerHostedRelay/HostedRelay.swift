/// The hosted relay client's namespace (#1239).
public enum HostedRelay {
    /// The relay wire protocol version: the `Relay-Protocol-Version` header and
    /// `Hello.protocol_version` (relay `gen/relay/v1/version.go`).
    public static let protocolVersion: UInt32 = 1
}
