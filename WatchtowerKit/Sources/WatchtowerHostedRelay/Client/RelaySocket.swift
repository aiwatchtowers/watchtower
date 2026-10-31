import Foundation
import os

/// What one read from the relay's WebSocket gave: a binary frame, or the
/// close the server sent (its code, custom 4xxx codes included).
public enum RelaySocketMessage: Equatable, Sendable {
    case binary(Data)
    case closed(code: Int)
}

/// One open WebSocket to the relay (`GET /v1/ws`). Every call may throw once
/// the socket is gone; `close` makes a pending `receive` or `ping` return or throw.
public protocol RelaySocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> RelaySocketMessage
    /// Returns on pong; the caller bounds it by 10 s.
    func ping() async throws
    func close(code: Int) async
}

/// Why the upgrade failed: the relay refused it with an HTTP status (401 =
/// log in again), or it got no answer.
public enum RelayDialError: Error, Equatable, Sendable {
    case http(status: Int)
    case unreachable
}

/// Opens the client's WebSocket. The headers carry the session token, so a
/// conformer never logs them.
public protocol RelaySocketDialer: Sendable {
    func dial(_ url: URL, headers: [String: String]) async throws -> any RelaySocket
}

/// `RelaySocketDialer` over `URLSessionWebSocketTask`. Close codes are read
/// from `closeCode.rawValue`, so the relay's 4000/4001/4008 survive (R13).
public struct URLSessionRelaySocketDialer: RelaySocketDialer {
    private let session: URLSession

    /// The ephemeral session of `URLSessionRelayHTTP` by default: nothing of a
    /// relay connection lands in a cookie store or a disk cache.
    public init(session: URLSession = URLSessionRelayHTTP.ephemeralSession) {
        self.session = session
    }

    public func dial(_ url: URL, headers: [String: String]) async throws -> any RelaySocket {
        // No `timeoutInterval`: on a WebSocket task it can act as an idle timeout and cut
        // a socket that is quiet between pings. The connection bounds the upgrade itself.
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.webSocketTask(with: request)
        // The Go client reads without a limit (`SetReadLimit(-1)`).
        task.maximumMessageSize = Int.max
        let opener = WebSocketOpener()
        task.delegate = opener
        try await withTaskCancellationHandler {
            try await opener.open(task)
        } onCancel: {
            task.cancel()
        }
        return URLSessionRelaySocket(task: task)
    }
}

/// Waits for the upgrade: `didOpen` → open; the task completing first → the
/// HTTP status the relay refused it with, else unreachable.
private final class WebSocketOpener: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let waiter = OSAllocatedUnfairLock<CheckedContinuation<Void, any Error>?>(initialState: nil)

    func open(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiter.withLock { $0 = continuation }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        finish(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if (error as? URLError)?.code == .cancelled { return finish(.failure(CancellationError())) }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
            return finish(.failure(RelayDialError.http(status: status)))
        }
        finish(.failure(RelayDialError.unreachable))
    }

    private func finish(_ result: Result<Void, any Error>) {
        let continuation = waiter.withLock { waiter in
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(with: result)
    }
}

/// An open `URLSessionWebSocketTask`.
private final class URLSessionRelaySocket: RelaySocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    /// Text frames are not part of the protocol and are skipped. A read that
    /// fails after the server's close frame is that close, by its raw code (R13).
    func receive() async throws -> RelaySocketMessage {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if task.closeCode != .invalid { return .closed(code: task.closeCode.rawValue) }
                throw error
            }
            if case .data(let data) = message { return .binary(data) }
        }
    }

    func ping() async throws {
        let once = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                // The pong handler may run again when the task is cancelled; resume once.
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close(code: Int) async {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    }
}
