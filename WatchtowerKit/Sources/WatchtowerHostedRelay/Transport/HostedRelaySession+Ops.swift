import Foundation
import WatchtowerRelayProto

/// The device's ops over its one socket (live link R2): a `Request` frame on the open socket, HTTPS
/// (`client.perform`) without one.
extension HostedRelaySession {
    /// One op: over the socket while it is live, else over HTTPS. The fallback is safe by what the
    /// relay may have run:
    /// - refused before its frame was handed to the socket (no live socket, a socket replaced
    ///   meanwhile): the op never reached the relay, so it goes over HTTPS whatever it is;
    /// - the socket lost after the frame was handed to it (the op may have run): only an idempotent op
    ///   is sent again over HTTPS, once — a read, or a save or delete whose every item is conditional
    ///   (`expected_seq` / `must_not_exist`). A resent save that conflicts with the very record it
    ///   carries met its own first write: that item is answered as saved. Any other op throws
    ///   `.unreachable`, as a lost HTTPS answer does, and its caller's own retry re-reads first.
    ///
    /// The public ops (`register`, `challenge`, `login`) always go over HTTPS: the socket's `Hello`
    /// needs the session they produce.
    public func send(_ op: Relay_V1_Request.OneOf_Op) async throws -> Relay_V1_Response {
        guard let connection, connection.isLive, Self.rides(op) else { return try await client.perform(op) }
        do {
            return try await connection.request(op)
        } catch HostedRelayConnection.SocketLoss.notSent {
            return try await client.perform(op)
        } catch HostedRelayConnection.SocketLoss.lost {
            let name = HostedRelayClient.name(op)
            guard Self.idempotent(op) else {
                Self.logger.error("relay \(name, privacy: .public): the socket dropped after the request, not resent")
                throw HostedRelayError.unreachable
            }
            Self.logger.info("relay \(name, privacy: .public): the socket dropped after the request, resent over HTTPS")
            return Self.ownWrites(in: try await client.perform(op), of: op)
        }
    }

    public func save(_ request: Relay_V1_Save) async throws -> Relay_V1_SaveResult {
        guard case .save(let result) = try await send(.save(request)).result else { throw Self.wrongAnswer }
        return result
    }

    public func delete(_ request: Relay_V1_Delete) async throws -> Relay_V1_DeleteResult {
        guard case .delete(let result) = try await send(.delete(request)).result else { throw Self.wrongAnswer }
        return result
    }

    /// A `TOKEN_EXPIRED` answer is the caller's: reset the zone's `since_seq` and pull again.
    public func changes(_ request: Relay_V1_Changes) async throws -> Relay_V1_ChangesResult {
        guard case .changes(let result) = try await send(.changes(request)).result else { throw Self.wrongAnswer }
        return result
    }

    // MARK: - Rules

    /// Whether `op` may go over the socket: every op but the public ones.
    static func rides(_ op: Relay_V1_Request.OneOf_Op) -> Bool {
        switch op {
        case .register, .challenge, .login: return false
        default: return true
        }
    }

    /// Whether running `op` twice leaves what running it once does: a read, or a write whose every item
    /// carries a precondition.
    static func idempotent(_ op: Relay_V1_Request.OneOf_Op) -> Bool {
        switch op {
        case .changes, .getAccountState, .getDownload:
            return true
        case .save(let save):
            return !save.items.isEmpty && save.items.allSatisfy { item in
                switch item.expect {
                case .expectedSeq?: return true
                case .mustNotExist(let on)?: return on
                case nil: return false
                }
            }
        case .delete(let delete):
            return !delete.items.isEmpty && delete.items.allSatisfy(\.hasExpectedSeq)
        default:
            return false
        }
    }

    /// `response` to a resent conditional save, each conflict whose current record is the item as sent
    /// (its first write ran before the socket dropped) turned into that item saved. Anything else, an
    /// answer that does not cover the request among it, is returned as it came.
    static func ownWrites(in response: Relay_V1_Response, of op: Relay_V1_Request.OneOf_Op) -> Relay_V1_Response {
        guard case .save(let request) = op, case .save(var result) = response.result,
              !result.conflicts.isEmpty, result.saved.count + result.conflicts.count == request.items.count
        else { return response }
        var conflicts: [Int: Relay_V1_SaveConflict] = [:]
        for conflict in result.conflicts {
            let index = Int(conflict.index)
            guard index < request.items.count, conflicts[index] == nil else { return response }
            conflicts[index] = conflict
        }
        var saved = result.saved.makeIterator()
        var answered: [Relay_V1_Record] = []
        var left: [Relay_V1_SaveConflict] = []
        for (index, item) in request.items.enumerated() {
            guard let conflict = conflicts[index] else {
                guard let record = saved.next() else { return response }
                answered.append(record)
                continue
            }
            if conflict.hasCurrent, isOwn(conflict.current, item.record) {
                answered.append(conflict.current)
            } else {
                left.append(conflict)
            }
        }
        result.saved = answered
        result.conflicts = left
        var mapped = response
        mapped.save = result
        return mapped
    }

    /// Whether the relay's `current` is `sent`, byte for byte.
    private static func isOwn(_ current: Relay_V1_Record, _ sent: Relay_V1_Record) -> Bool {
        !current.deleted && current.name == sent.name && current.envelope == sent.envelope
            && current.clientModifiedAtMs == sent.clientModifiedAtMs && current.attachmentID == sent.attachmentID
    }

    private static var wrongAnswer: HostedRelayError {
        .undecodable(status: 200)
    }
}
