import Foundation

/// How a `TowerClient` reaches the tower: the Mac's daemon socket
/// (`SocketTransport`, WatchtowerCore) or the phone's hub (`HubTransport`).
/// A transport sends frames and knows nothing of the client's states,
/// retries or request ids.
public protocol TowerTransport: Sendable {
    /// Sends one request and returns its response (any status). Throws
    /// `TowerTransportError.down` when the tower cannot be reached or the
    /// connection closed before the answer.
    func call(_ request: Request) async throws -> Response

    /// Opens a watch command: the stream yields its `changed` events until
    /// the consumer stops (which closes the watch). It ends throwing
    /// `.refused` when the tower refuses the watch, and `.down` when the
    /// connection is lost.
    func watch(_ request: Request) -> AsyncThrowingStream<ChangedEvent, Error>
}

public enum TowerTransportError: Error, Equatable, Sendable {
    /// The tower cannot be reached, or the connection closed.
    case down
    /// The tower refused a watch.
    case refused(Refusal)
}
