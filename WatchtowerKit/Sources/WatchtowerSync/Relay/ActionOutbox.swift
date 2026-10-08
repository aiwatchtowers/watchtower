import Foundation

/// Why `ActionOutbox.enqueue` refused to ship an action.
public enum ActionOutboxError: Error, Equatable {
    /// No linked device id yet: the hub fails every record without one as
    /// `device_not_linked` (spec §5.2 rule 4), so nothing is sent.
    case notLinked
}

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
    /// Overlay error text for a failed echo that carried no message.
    public static let noMessageFallback = "Failed on the desktop (no message)"

    /// Plain internet-date-time UTC ("2026-07-10T12:00:00Z"). Thread-safe
    /// per Apple's docs, so a shared instance is fine.
    private static let snoozeFormatter = ISO8601DateFormatter()

    private let transport: any CloudSyncTransport
    private let store: ReplicaStore
    private let now: @Sendable () -> Date
    /// The linked phone's device id, stamped on every enqueued action. nil
    /// until linking finishes (or after an unlink): enqueue then refuses.
    private var deviceID: String?
    /// Told about each `applied` echo whose overlay row it removed.
    private var appliedObserver: (@Sendable (ActionRequestPayload) -> Void)?

    public init(
        transport: any CloudSyncTransport,
        store: ReplicaStore,
        deviceID: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.store = store
        self.deviceID = deviceID
        self.now = now
    }

    /// Called by the link flow once the device is linked, and with nil on
    /// unlink. Actions already in flight keep the id they were sent with.
    public func setDeviceID(_ deviceID: String?) {
        self.deviceID = deviceID
    }

    /// The overlay row goes on `applied`, so this is how the app reads an
    /// applied echo's `result` (an ask answer's `delivery`). Called on this
    /// actor, once per row an `applied` echo removes: never for a
    /// redelivered echo or an unknown action id.
    public func setAppliedObserver(_ observer: (@Sendable (ActionRequestPayload) -> Void)?) {
        appliedObserver = observer
    }

    /// The `snooze_until` param in the wire's frozen form: plain ISO8601 UTC,
    /// second precision. The desktop parser accepts plain + fractional forms
    /// (pinned in Plan 2/3); mobile always sends plain.
    public static func snoozeParams(until date: Date) -> [String: JSONValue] {
        ["snooze_until": .string(snoozeFormatter.string(from: date))]
    }

    /// Builds and ships one ActionRequest stamped with the linked device id;
    /// returns its id. Throws `ActionOutboxError.notLinked` (sending
    /// nothing) while no device id is set.
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
        guard let deviceID else { throw ActionOutboxError.notLinked }
        let action = ActionRequestPayload(
            id: UUID().uuidString,
            kind: kind,
            entityID: Self.entityID(from: entityRecordName),
            params: params,
            createdAt: now(),
            deviceID: deviceID
        )
        try await transport.save([try CloudRecordFactory.record(for: action, modifiedAt: action.createdAt)])
        try store.insertPendingAction(action, entityRecordName: entityRecordName)
        return action.id
    }

    /// Resolves the overlay from a desktop echo (called by `RelayFeed`):
    /// `applied` removes the pending row (the authoritative slice change
    /// arrives via hydration); `failed`, `expired` and `cancelled` flip it
    /// with the desktop's message, reason and result; `received` and `held`
    /// leave it pending.
    /// Echoes for unknown action_ids are no-ops — redelivery after a sweep
    /// removed the row, or the phantom case documented on `enqueue`. A
    /// still-`pending` payload is our own enqueue reflecting back: inert.
    public func applyEcho(_ action: ActionRequestPayload) throws {
        switch action.status {
        case .pending, .received, .held:
            // Still in flight on the Mac: the overlay stays pending.
            break
        case .applied:
            if try store.removePendingAction(id: action.id) {
                appliedObserver?(action)
            }
        case .failed, .expired, .cancelled:
            try store.markPendingActionFailed(
                id: action.id,
                errorMessage: action.errorMessage ?? Self.noMessageFallback,
                reason: action.reason,
                result: action.result
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
