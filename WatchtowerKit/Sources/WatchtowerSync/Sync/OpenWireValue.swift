import Foundation

/// A wire string whose set of values a newer writer may extend (a new
/// flavor, sharing state, account kind, scope or refusal code).
///
/// Unlike a closed `String` enum, decoding never fails: a value this build
/// does not know keeps its raw string, reads as `isKnown == false`, and
/// re-encodes unchanged. So one new value from a newer Mac cannot make an
/// older phone drop the whole payload (mobile POC spec §2.2: old and new
/// versions interoperate). Conformers declare their known values as static
/// constants and list them in `knownValues`, in wire order.
public protocol OpenWireValue: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    init(rawValue: String)
    /// The values this build knows, in their frozen wire order.
    static var knownValues: [Self] { get }
}

extension OpenWireValue {
    /// False for a value written by a newer build.
    public var isKnown: Bool { Self.knownValues.contains(self) }
}
