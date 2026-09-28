import Foundation

/// Frames NDJSON on byte 0x0A only. Foundation's `lines` also breaks on
/// U+0085 (NEL), U+2028/2029 and `\r`, and Go's `json.Marshal` leaves a raw
/// U+0085 inside strings — so a Unicode-aware splitter would cut such an
/// event in two unparseable halves and silently drop it. A partial line is
/// kept across `append` calls until its `\n` arrives.
package struct NDJSONLineSplitter: Sendable {
    private var buffer: [UInt8] = []

    package init() {}

    /// Feeds bytes; returns every line completed by them (without the `\n`).
    package mutating func append(_ bytes: some Sequence<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            if byte == 0x0A {
                lines.append(Self.decode(buffer))
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }
        return lines
    }

    /// The unterminated tail at EOF, if any.
    package mutating func finish() -> String? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : Self.decode(buffer)
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        // An invalid sequence becomes U+FFFD; the JSON parser then rejects or
        // keeps the line on its own terms — framing never drops bytes.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }
}
