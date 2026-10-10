import Foundation
import WatchtowerSync

/// A phone-side mirror of one hub-computed DataZone slice (mobile POC spec
/// §4): the record's payload decoded as the hub projected it.
///
/// Wire: RelayCoder JSON (snake_case keys, Unix-second dates, sorted keys),
/// as for `heartbeat` and `device_grant`. A nil optional is an absent key;
/// unknown keys are ignored, so a newer Mac's extra fields never break an
/// older phone. Enum-like fields are `OpenWireValue`s for the same reason.
public protocol SliceMirror: Decodable, Hashable, Sendable {
    /// The slice kind whose records this mirror decodes.
    static var sliceKind: SliceKind { get }
}

extension SliceMirror {
    /// Decodes one record's payload.
    public static func decode(payload: Data) throws -> Self {
        try RelayCoder.makeDecoder().decode(Self.self, from: payload)
    }
}
