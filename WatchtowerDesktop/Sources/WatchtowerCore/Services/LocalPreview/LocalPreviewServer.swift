import Foundation
import Network

/// The loopback HTTP server behind "Open in Browser" for html artifacts and
/// workbench html files (board #535). One per app, started on first use and
/// stopped on quit. It listens on 127.0.0.1 only, on a random port, accepts
/// local connections only, and serves only what was registered — each
/// registration under its own unguessable token (`LocalPreviewHTTP` holds
/// the routing). It never opens a connection of its own.
package final class LocalPreviewServer: @unchecked Sendable {
    package static let shared = LocalPreviewServer()

    package enum Failure: Error, LocalizedError {
        case unavailable(String)

        package var errorDescription: String? {
            switch self {
            case let .unavailable(reason): "The local preview server could not start: \(reason)"
            }
        }
    }

    private let queue = DispatchQueue(label: "watchtower.local-preview")
    private let lock = NSLock()
    private var registry = LocalPreviewRegistry()
    private var listener: NWListener?
    private var port: UInt16?
    private var waiters: [CheckedContinuation<UInt16, Error>] = []

    package init() {}

    /// Registers `source` under `id` (its token kept across calls) and
    /// returns the URL of `file` in it (`index.html` for a page), starting
    /// the server on first use.
    package func url(for source: LocalPreviewSource, id: String, file: String = "index.html") async throws -> URL {
        let token = lock.withLock { registry.register(id: id, source: source) }
        let port = try await ensureStarted()
        let allowed = CharacterSet.urlPathAllowed.subtracting(["/", "?", "#"])
        let segments = file.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let path = segments.joined(separator: "/")
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/\(path)") else {
            throw Failure.unavailable("bad file name")
        }
        return url
    }

    package func unregister(id: String) {
        lock.withLock { registry.unregister(id: id) }
    }

    /// Stops listening and forgets every registration (the app quits).
    package func stop() {
        let stopped: NWListener? = lock.withLock {
            let current = listener
            listener = nil
            port = nil
            registry = LocalPreviewRegistry()
            failWaitersLocked("stopped")
            return current
        }
        stopped?.cancel()
    }

    private func ensureStarted() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let port {
                    continuation.resume(returning: port)
                    return
                }
                waiters.append(continuation)
                if listener == nil { startLocked() }
            }
        }
    }

    private func startLocked() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let created: NWListener
        do {
            created = try NWListener(using: parameters)
        } catch {
            failWaitersLocked(error.localizedDescription)
            return
        }
        listener = created
        created.stateUpdateHandler = { [weak self, weak created] state in
            guard let self, let created else { return }
            self.listenerChanged(state, created)
        }
        created.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        created.start(queue: queue)
    }

    private func listenerChanged(_ state: NWListener.State, _ changed: NWListener) {
        switch state {
        case .ready:
            lock.withLock {
                guard listener === changed, let raw = changed.port?.rawValue else { return }
                port = raw
                let ready = waiters
                waiters = []
                ready.forEach { $0.resume(returning: raw) }
            }
        case let .failed(error), let .waiting(error):
            changed.cancel()
            lock.withLock {
                guard listener === changed else { return }
                listener = nil
                port = nil
                failWaitersLocked(error.localizedDescription)
            }
        default:
            break
        }
    }

    private func failWaitersLocked(_ reason: String) {
        let failed = waiters
        waiters = []
        failed.forEach { $0.resume(throwing: Failure.unavailable(reason)) }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A client that never finishes its request is dropped.
        queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch LocalPreviewHTTP.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            case .malformed:
                self.reply(LocalPreviewHTTP.error(400), includeBody: true, on: connection)
            case let .request(request):
                let response = LocalPreviewHTTP.respond(to: request) { token in
                    self.lock.withLock { self.registry.source(token: token) }
                }
                self.reply(response, includeBody: request.method != "HEAD", on: connection)
            }
        }
    }

    private func reply(_ response: LocalPreviewResponse, includeBody: Bool, on connection: NWConnection) {
        connection.send(content: response.serialized(includeBody: includeBody), contentContext: .finalMessage,
                        isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
}
