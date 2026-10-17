import Foundation

/// Frame types of the session host wire protocol (Go `internal/sessionhost`,
/// a dual path): one type byte, a big-endian `UInt32` payload length, the
/// payload. Requests are below 0x80, replies and pushes have the high bit.
package enum SessionHostFrameType: UInt8, Sendable {
    case hello = 0x01
    case helloOK = 0x81
    case launch = 0x02
    case launched = 0x82
    case attach = 0x03
    case attached = 0x83
    case input = 0x04
    case resize = 0x05
    case output = 0x84
    case exit = 0x85
    case list = 0x06
    case listed = 0x86
    case forget = 0x07
    case forgot = 0x87
    case error = 0x8F
}

package enum SessionHostFrameError: Error, Equatable, Sendable {
    /// The declared payload is over `SessionHostFrame.maxPayload`.
    case tooLarge(Int)
}

package struct SessionHostFrame: Equatable, Sendable {
    package static let maxPayload = 1 << 20
    package static let headerSize = 5

    package let type: SessionHostFrameType
    package let payload: [UInt8]

    package init(type: SessionHostFrameType, payload: [UInt8] = []) {
        self.type = type
        self.payload = payload
    }

    /// Callers split an `input` larger than `maxPayload` into several frames.
    package func encoded() -> [UInt8] {
        precondition(payload.count <= Self.maxPayload, "session host frame payload over 1 MiB")
        let length = UInt32(payload.count)
        return [type.rawValue,
                UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)] + payload
    }
}

/// Reassembles frames from a byte stream. A frame of an unknown type is
/// skipped whole (the protocol only grows additively and the app and the
/// host are separate binaries). After a throw the stream is corrupt: the
/// caller closes the connection.
package struct SessionHostFrameDecoder: Sendable {
    private var buffer: [UInt8] = []

    package init() {}

    package mutating func append(_ bytes: [UInt8]) throws -> [SessionHostFrame] {
        buffer += bytes
        var frames: [SessionHostFrame] = []
        var offset = 0
        while buffer.count - offset >= SessionHostFrame.headerSize {
            let length = buffer[(offset + 1)...(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= SessionHostFrame.maxPayload else { throw SessionHostFrameError.tooLarge(length) }
            let end = offset + SessionHostFrame.headerSize + length
            guard buffer.count >= end else { break }
            if let type = SessionHostFrameType(rawValue: buffer[offset]) {
                frames.append(SessionHostFrame(type: type, payload: Array(buffer[(offset + SessionHostFrame.headerSize)..<end])))
            }
            offset = end
        }
        buffer.removeFirst(offset)
        return frames
    }
}
