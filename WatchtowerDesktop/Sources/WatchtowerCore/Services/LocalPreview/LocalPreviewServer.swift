import Foundation
import Network

/// The loopback HTTP server behind "Open in Browser" for workbench html
/// files (board #535). One per app, started on first use and stopped on
/// quit. It listens on 127.0.0.1 only, on a random port, accepts local
/// connections only, and serves only the folders registered with it — each
/// under its own unguessable token (`LocalPreviewHTTP` holds the routing).
/// It never opens a connection of its own (pinned by a source scan). Chat
/// artifacts never come here (CHAT-05).
package final class LocalPreviewServer: @unchecked Sendable {
    package static let shared = LocalPreviewServer()

    package enum Failure: Error, LocalizedError {
        case unavailable(String)
        /// The folder is hidden, or hidden inside the workbench.
        case refused

        package var errorDescription: String? {
            switch self {
            case let .unavailable(reason): "The local preview server could not start: \(reason)"
            case .refused: "Files in a hidden folder are not opened in the browser."
            }
        }
    }

    /// A client that has not sent its whole request header by then is dropped.
    /// The send that follows is not timed: a big file is never cut off.
    private static let headerTimeout: TimeInterval = 15
    /// How much of a file is read and sent at a time.
    private static let chunkBytes = 256 * 1024

    /// Accepts and reads requests; replies are built off it (`replyQueue`),
    /// so a big file never holds up another connection.
    private let queue = DispatchQueue(label: "watchtower.local-preview")
    private let replyQueue = DispatchQueue(label: "watchtower.local-preview.reply", attributes: .concurrent)
    private let lock = NSLock()
    private var registry = LocalPreviewRegistry()
    private var listener: NWListener?
    private var port: UInt16?
    private var waiters: [CheckedContinuation<UInt16, Error>] = []

    package init() {}

    /// Registers `folder` under `id` (its token kept across calls) and
    /// returns the URL of `file` in it, starting the server on first use.
    /// `folder` must be servable within the code root `root`
    /// (`LocalPreviewHTTP.servableFolder`: no hidden folder below it).
    package func url(forFile file: String, inFolder folder: URL, within root: URL, id: String) async throws -> URL {
        guard let servable = LocalPreviewHTTP.servableFolder(folder, within: root) else {
            throw Failure.refused
        }
        let token = lock.withLock { registry.register(id: id, folder: servable) }
        let port = try await ensureStarted()
        // No "%" either: a literal "%20" in a file name must stay a name.
        let allowed = CharacterSet.urlPathAllowed.subtracting(["/", "?", "#", "%"])
        let segments = file.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/\(segments.joined(separator: "/"))") else {
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

    /// Per connection, touched on `queue` only.
    private final class Pending {
        var headerRead = false
    }

    private func serve(_ connection: NWConnection) {
        let pending = Pending()
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.headerTimeout) {
            if !pending.headerRead { connection.cancel() }
        }
        receive(connection, pending: pending, buffer: Data())
    }

    private func receive(_ connection: NWConnection, pending: Pending, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch LocalPreviewHTTP.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, pending: pending, buffer: buffer)
                }
            case .malformed:
                pending.headerRead = true
                self.reply(LocalPreviewHTTP.error(400), includeBody: true, on: connection)
            case let .request(request):
                pending.headerRead = true
                self.replyQueue.async {
                    let port = self.lock.withLock { self.port } ?? 0
                    let response = LocalPreviewHTTP.respond(to: request, port: port) { token in
                        self.lock.withLock { self.registry.folder(token: token) }
                    }
                    self.reply(response, includeBody: request.method != "HEAD", on: connection)
                }
            }
        }
    }

    /// Sends the head (and an in-memory body); a file body follows in
    /// `chunkBytes` pieces read one at a time, so a reply never holds more
    /// than one chunk of a file in memory (#563). A HEAD never opens it.
    private func reply(_ response: LocalPreviewResponse, includeBody: Bool, on connection: NWConnection) {
        var response = response
        var handle: FileHandle?
        if includeBody, let file = response.file {
            handle = try? FileHandle(forReadingFrom: file)
            if handle == nil { response = LocalPreviewHTTP.error(404) }
        }
        let length = Int(response.header("Content-Length") ?? "") ?? 0
        guard let handle, length > 0 else {
            try? handle?.close()
            connection.send(content: response.serialized(includeBody: includeBody), contentContext: .finalMessage,
                            isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        // Each piece goes as a complete message (TCP has no message
        // boundaries); a partial one would sit unsent until completed.
        connection.send(content: response.serialized(includeBody: false), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? handle.close()
                return connection.cancel()
            }
            self.replyQueue.async { self.stream(handle, remaining: length, on: connection) }
        })
    }

    /// One file chunk per turn; the next is read once this one is sent. A
    /// file that shrank since its Content-Length was taken cuts the
    /// connection rather than send a short body as whole.
    private func stream(_ handle: FileHandle, remaining: Int, on connection: NWConnection) {
        guard let chunk = try? handle.read(upToCount: min(remaining, Self.chunkBytes)), !chunk.isEmpty else {
            try? handle.close()
            return connection.cancel()
        }
        let left = remaining - chunk.count
        // The last piece also closes the send side.
        connection.send(content: chunk, contentContext: left == 0 ? .finalMessage : .defaultMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            guard let self, error == nil, left > 0 else {
                                try? handle.close()
                                return connection.cancel()
                            }
                            self.replyQueue.async { self.stream(handle, remaining: left, on: connection) }
                        })
    }
}
