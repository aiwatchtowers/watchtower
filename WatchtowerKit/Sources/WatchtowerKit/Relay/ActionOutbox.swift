import Foundation

/// The phone's action producer: enqueues ActionRequests into the relay zone
/// and mirrors each into the replica DB's `pending_actions` overlay, so view
/// models can render optimistic state without ever mutating `slice_records`
/// (Plan 4 decision 4 — overlay, not mutation).
///
/// Lifecycle of one action:
/// 1. `enqueue` — relay record saved, overlay row inserted (`pending`).
/// 2. Desktop applies it and rewrites the record with `applied`/`failed`;
///    `RelayFeed` routes that echo to `applyEcho`, which clears the overlay
///    row or flips it to `failed` with the desktop's message.
/// 3. No echo within ~24 h (Plan 3 notes: an undecodable payload can never
///    be echoed — the desktop has no addressable id) — `sweepSilentPending`
///    fails the row locally so the user learns instead of trusting a chip.
public actor ActionOutbox {
    /// Overlay error text for actions the desktop never echoed.
    static let silentPendingMessage =
        "No response from your Mac — the action may not have been applied."

    /// Plain internet-date-time UTC ("2026-07-10T12:00:00Z"). Thread-safe
    /// per Apple's docs, so a shared instance is fine.
    private static let snoozeFormatter = ISO8601DateFormatter()

    private let transport: any CloudSyncTransport
    private let store: ReplicaStore
    private let now: @Sendable () -> Date

    public init(
        transport: any CloudSyncTransport,
        store: ReplicaStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.store = store
        self.now = now
    }

    /// The `snooze_until` param in the wire's frozen form: plain ISO8601 UTC,
    /// second precision. The desktop parser accepts plain + fractional forms
    /// (pinned in Plan 2/3); mobile always sends plain.
    public static func snoozeParams(until date: Date) -> [String: JSONValue] {
        ["snooze_until": .string(snoozeFormatter.string(from: date))]
    }

    /// Builds and ships one ActionRequest; returns its id.
    ///
    /// `entityRecordName` is the slice recordName the action targets
    /// (`target-42`) — the wire `entityID` is its id suffix ("42"), which the
    /// desktop resolves to a DB row. Pass nil for entity-less kinds
    /// (`task_create`).
    ///
    /// Ordering: transport save FIRST, overlay row second. A transport throw
    /// therefore leaves no phantom pending chip. The reverse failure (record
    /// saved, insert throws) means the desktop applies an action the overlay
    /// never knew about — harmless: its echo hits an unknown action_id, a
    /// no-op, and the result arrives with the next slice hydration anyway.
    /// The reentrancy variant of that orphan: an echo delivered while this
    /// actor is suspended in `save` also no-ops on the not-yet-inserted
    /// action_id, and the later insert then leaves a pending row for an
    /// already-applied action — which the 24 h sweep flips to a false
    /// failure. Self-heals (the authoritative row change arrives via
    /// hydration; the stale chip is dismissable) and is unreachable at real
    /// cadence: an echo takes seconds at minimum, the insert follows the
    /// save within the same call.
    @discardableResult
    public func enqueue(
        kind: ActionKind,
        entityRecordName: String?,
        params: [String: JSONValue] = [:]
    ) async throws -> String {
        let action = ActionRequestPayload(
            id: UUID().uuidString,
            kind: kind,
            entityID: Self.entityID(from: entityRecordName),
            params: params,
            createdAt: now()
        )
        try await transport.save([try CloudRecordFactory.record(for: action, modifiedAt: action.createdAt)])
        try store.insertPendingAction(action, entityRecordName: entityRecordName)
        return action.id
    }

    /// Resolves the overlay from a desktop echo (called by `RelayFeed`):
    /// `applied` removes the pending row (the authoritative slice change
    /// arrives via hydration), `failed` flips it with the desktop's message.
    /// Echoes for unknown action_ids are no-ops — redelivery after a sweep
    /// removed the row, or the phantom case documented on `enqueue`. A
    /// still-`pending` payload is our own enqueue reflecting back: inert.
    public func applyEcho(_ action: ActionRequestPayload) throws {
        switch action.status {
        case .pending:
            break
        case .applied:
            try store.removePendingAction(id: action.id)
        case .failed:
            try store.markPendingActionFailed(
                id: action.id,
                errorMessage: action.errorMessage ?? "Failed on the desktop (no message)"
            )
        }
    }

    /// Fails (locally) every row still `pending` after `age` — default 24 h,
    /// the Plan 3 notes' silent-pending rule. Returns the swept ids.
    @discardableResult
    public func sweepSilentPending(olderThan age: Duration = .seconds(86_400)) throws -> [String] {
        let seconds = TimeInterval(age.components.seconds)
            + TimeInterval(age.components.attoseconds) / 1e18
        return try store.sweepPendingActions(
            before: now().addingTimeInterval(-seconds),
            errorMessage: Self.silentPendingMessage
        )
    }

    /// `target-42` → "42", `inbox_item-7` → "7": SliceKind rawValues never
    /// contain hyphens (underscores only), so everything after the FIRST
    /// hyphen is the id — even if the id itself contains hyphens. A name
    /// without a hyphen passes through unchanged; the desktop rejects a
    /// non-numeric id with a `failed` echo, so a malformed name self-surfaces.
    private static func entityID(from recordName: String?) -> String? {
        guard let recordName else { return nil }
        guard let hyphen = recordName.firstIndex(of: "-") else { return recordName }
        return String(recordName[recordName.index(after: hyphen)...])
    }
}
