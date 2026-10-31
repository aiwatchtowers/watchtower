import Foundation

/// Conditional mailbox writes (`ConditionalTransport`) through the secure layer. The records are already sealed
/// (`seal` returned them, wire names), so they are forwarded unchanged, like `saveSealed(_: [CloudRecord])`. A
/// conflict's current record is still sealed; `openConflict` opens it.
extension SecureTransport {
    /// The inner transport takes conditional writes.
    nonisolated public var isConditional: Bool {
        inner is any ConditionalTransport
    }

    /// One outcome per item, in order. Throws `SecureTransportError.notConditional` when the inner transport is not.
    public func saveSealed(_ items: [ConditionalSave]) async throws -> [SaveOutcome] {
        try await conditionalInner().save(items)
    }

    /// Wire names, forwarded. Throws `SecureTransportError.notConditional` when the inner transport is not.
    public func deleteSealed(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome] {
        try await conditionalInner().delete(items)
    }

    /// Opens a conflict's current RelayZone record the way `changes` does (role keys, kinds, name binding, rollback
    /// guard). nil when it does not open (another sender's, garbage, an older version) or is not a RelayZone record.
    /// Throws `keysUnavailable` on a locked keychain.
    public func openConflict(_ current: CloudRecord) throws -> CloudRecord? {
        guard current.zone == .relay else { return nil }
        guard case .opened(let plain) = try open(current) else { return nil }
        return plain
    }

    private func conditionalInner() throws -> any ConditionalTransport {
        guard let conditional = inner as? any ConditionalTransport else { throw SecureTransportError.notConditional }
        return conditional
    }
}
