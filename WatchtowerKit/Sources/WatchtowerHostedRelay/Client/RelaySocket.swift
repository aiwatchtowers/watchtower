/// Opens the client's WebSocket (`GET /v1/ws`). Declared here so
/// `HostedRelayClient` can take one; Task 5 gives it its requirements and its
/// `URLSession` conformer.
public protocol RelaySocketDialer: Sendable {}
