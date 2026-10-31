import Foundation
import WatchtowerRelayProto

/// A parsed zone name (README "Zone names"); nil for anything else, which nobody may touch.
enum ZoneName: Equatable {
    case data(hub: String)
    case mailbox(hub: String, phone: String)
    case pair(slot: String)

    init?(_ name: String) {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let ids = Array(parts.dropFirst())
        guard let kind = parts.first, !ids.isEmpty, !ids.contains(where: \.isEmpty) else { return nil }
        switch (kind, ids.count) {
        case ("data", 1): self = .data(hub: ids[0])
        case ("relay", 2): self = .mailbox(hub: ids[0], phone: ids[1])
        case ("pair", 1): self = .pair(slot: ids[0])
        default: return nil
        }
    }
}

/// Records of zones: per-zone `server_seq`, the last version of each record,
/// tombstones, conditional writes, paged changes, retention, quotas and
/// attachments (README "Operations notes", "Errors"; Worker `do/zone/*`).
extension FakeHostedRelay {
    struct Zone {
        struct Record {
            let name: String
            var envelope: Data
            var modifiedMs: Int64
            var seq: UInt64
            var attachmentID: String?
            var deleted: Bool
            var updatedAt: Date
        }

        /// Only grows; a token above it is `TOKEN_EXPIRED`.
        var lastSeq: UInt64 = 0
        /// The highest purged tombstone's seq: a token below it is `TOKEN_EXPIRED`.
        var floorSeq: UInt64 = 0
        var records: [String: Record] = [:]
        /// Live attachments: id → size.
        var attachments: [String: Int] = [:]
        /// Data zone only: the phones its Mac lets read (`set_hub_readers`).
        var readers: Set<String> = []

        /// Bytes toward the quota: live envelopes plus attachments.
        var usage: Int {
            records.values.filter { !$0.deleted }.reduce(0) { $0 + $1.envelope.count } + attachments.values.reduce(0, +)
        }

        /// Tombstones `name` with a new seq (nothing for a missing record or a tombstone).
        mutating func tombstone(_ name: String, at now: Date) {
            guard var record = records[name], !record.deleted else { return }
            lastSeq += 1
            let attachment = record.attachmentID
            record.envelope = Data()
            record.attachmentID = nil
            record.deleted = true
            record.seq = lastSeq
            record.updatedAt = now
            records[name] = record
            release(attachment)
        }

        /// Drops an attachment no live record references any more (one live record per attachment).
        mutating func release(_ attachmentID: String?) {
            guard let attachmentID, !records.values.contains(where: { !$0.deleted && $0.attachmentID == attachmentID }) else { return }
            attachments[attachmentID] = nil
        }
    }

    enum ZoneOp {
        case save, delete, read
    }

    // MARK: - Access (Worker acl.ts zoneAccess)

    /// The parsed zone when `session` may `op` it, after its retention ran; the refusal otherwise.
    @discardableResult
    func access(_ name: String, _ session: Session, _ op: ZoneOp) throws -> ZoneName {
        guard let zone = ZoneName(name) else { throw RelayFailure.forbidden }
        tidy(name)
        switch zone {
        case .data(let hub): try dataAccess(name, hub: hub, session, op)
        case let .mailbox(hub, phone): try mailboxAccess(hub: hub, phone: phone, session, op)
        case .pair(let slot): try pairAccess(slot: slot, session)
        }
        return zone
    }

    /// Data zone: the Mac writes while an account that slots it pays (`ENTITLEMENT_INACTIVE` when
    /// only lapsed ones do) and reads while one can read; a phone reads when the Mac made it a
    /// reader and its own account slots the Mac and can read.
    private func dataAccess(_ name: String, hub: String, _ session: Session, _ op: ZoneOp) throws {
        let now = now
        let holding = state.accounts.values.filter { $0.macs.contains(hub) }
        if session.kind == .mac, session.deviceID == hub {
            let allowed = op == .read ? holding.contains { $0.readable(at: now) } : holding.contains(where: \.paying)
            if allowed { return }
            throw !holding.isEmpty && op != .read ? RelayFailure.entitlementInactive : RelayFailure.forbidden
        }
        let reader = state.zones[name]?.readers.contains(session.deviceID) == true
        if session.kind == .phone, op == .read, reader,
           holding.contains(where: { $0.phoneID == session.deviceID && $0.readable(at: now) }) {
            return
        }
        throw RelayFailure.forbidden
    }

    /// Mailbox: only that phone and the hub's Mac, and the phone's account must slot the hub;
    /// save needs it paying, read the read window; the phone may always delete in its own mailbox.
    private func mailboxAccess(hub: String, phone: String, _ session: Session, _ op: ZoneOp) throws {
        let isPhone = session.kind == .phone && session.deviceID == phone
        let isMac = session.kind == .mac && session.deviceID == hub
        guard isPhone || isMac else { throw RelayFailure.forbidden }
        if op == .delete, isPhone { return }
        let held = state.accounts.values.filter { $0.phoneID == phone && $0.macs.contains(hub) }
        guard !held.isEmpty else { throw RelayFailure.forbidden }
        switch op {
        case .delete: return
        case .save: guard held.contains(where: \.paying) else { throw RelayFailure.entitlementInactive }
        case .read: guard held.contains(where: { $0.readable(at: now) }) else { throw RelayFailure.forbidden }
        }
    }

    /// Pair zone: the two participants of an unexpired pairing.
    private func pairAccess(slot: String, _ session: Session) throws {
        guard let (accountID, pairing) = pairing(slotID: slot), now < pairing.expiresAt else { throw RelayFailure.forbidden }
        let isPhone = session.kind == .phone && state.accounts[accountID]?.phoneID == session.deviceID
        let isMac = session.kind == .mac && pairing.macID == session.deviceID
        guard isPhone || isMac else { throw RelayFailure.forbidden }
    }

    // MARK: - Retention

    /// What the Worker's alarms would have done by now: mailbox records older than 14 days
    /// become tombstones; tombstones older than 30 days are purged and raise the floor.
    private func tidy(_ name: String) {
        if case .mailbox = ZoneName(name) {
            // Stamped when the Worker's alarm would have expired it, so the purge below runs on time.
            expireMailbox(name, before: now.addingTimeInterval(-RelayTTL.mailbox)) { $0.updatedAt.addingTimeInterval(RelayTTL.mailbox) }
        }
        guard var zone = state.zones[name] else { return }
        let horizon = now.addingTimeInterval(-RelayTTL.tombstone)
        let purged = zone.records.values.filter { $0.deleted && $0.updatedAt < horizon }
        guard !purged.isEmpty else { return }
        for record in purged { zone.records[record.name] = nil }
        zone.floorSeq = max(zone.floorSeq, purged.map(\.seq).max() ?? 0)
        state.zones[name] = zone
    }

    /// Tombstones the live records of a mailbox last written before `before` (mailbox TTL),
    /// in name order (Worker `expireRecords`), each stamped with `stamp(record)`.
    func expireMailbox(_ name: String, before: Date, stamp: (Zone.Record) -> Date) {
        guard var zone = state.zones[name] else { return }
        for record in zone.records.values.sorted(by: { $0.name < $1.name }) where !record.deleted && record.updatedAt < before {
            zone.tombstone(record.name, at: stamp(record))
        }
        state.zones[name] = zone
    }

    // MARK: - Quotas

    /// README "Operations notes" and Worker `quota.ts`: the new bytes are added to the current
    /// usage without subtracting what they replace.
    private func checkQuota(_ name: String, _ zone: ZoneName, adding bytes: Int) throws {
        let usage = state.zones[name]?.usage ?? 0
        let limits = state.limits
        switch zone {
        case .data:
            if usage + bytes > limits.hubQuotaBytes { throw RelayFailure(.hubQuotaExceeded, "hub quota exceeded") }
        case .mailbox(_, let phone):
            let mailboxes = state.zones.keys.filter { if case .mailbox(_, phone)? = ZoneName($0) { true } else { false } }
            for mailbox in mailboxes { tidy(mailbox) }
            let all = state.zones.reduce(0) { sum, entry in
                guard case .mailbox(_, phone)? = ZoneName(entry.key) else { return sum }
                return sum + entry.value.usage
            }
            if all + bytes > limits.mailboxQuotaBytes { throw RelayFailure(.mailboxQuotaExceeded, "mailbox quota exceeded") }
        case .pair:
            if usage + bytes > limits.pairZoneBytes { throw RelayFailure(.mailboxQuotaExceeded, "mailbox quota exceeded") }
        }
    }

    // MARK: - Save

    /// Worker ops.ts `save`: sizes first (`RECORD_TOO_LARGE` refuses the call), then every zone's
    /// access and quota, then each item's precondition. A conflict is per item and consumes no
    /// seq; a missing (`NOT_FOUND`) or taken (`CONFLICT`) attachment refuses the whole call.
    /// `saved` carries metadata only; `conflicts` carry the current record, or none.
    func save(_ items: [Relay_V1_SaveItem], _ session: Session) throws -> Relay_V1_Response {
        guard items.allSatisfy(\.hasRecord) else { throw RelayFailure.invalid }
        guard items.allSatisfy({ $0.record.envelope.count <= state.limits.maxRecordBytes }) else {
            throw RelayFailure(.recordTooLarge, "record too large")
        }
        var groups: [(zone: String, items: [(index: Int, item: Relay_V1_SaveItem)])] = []
        for (index, item) in items.enumerated() {
            if let at = groups.firstIndex(where: { $0.zone == item.record.zone }) {
                groups[at].items.append((index, item))
            } else {
                groups.append((item.record.zone, [(index, item)]))
            }
        }
        for group in groups {
            let zone = try access(group.zone, session, .save)
            try checkQuota(group.zone, zone, adding: group.items.reduce(0) { $0 + $1.item.record.envelope.count })
        }
        var result = Relay_V1_SaveResult()
        var updated: [String: Zone] = [:]
        for group in groups {
            var zone = state.zones[group.zone] ?? Zone()
            var replaced: [String] = []
            for (index, item) in group.items {
                if case .conflict(let current) = try saveOne(item, into: &zone, replaced: &replaced) {
                    var conflict = Relay_V1_SaveConflict()
                    conflict.index = UInt32(index)
                    if let current { conflict.current = Self.proto(current, zone: group.zone, envelope: true) }
                    result.conflicts.append(conflict)
                } else if let saved = zone.records[item.record.name] {
                    result.saved.append(Self.proto(saved, zone: group.zone, envelope: false))
                }
            }
            // Released after the whole group (Worker `saveRecords`), so a later item may take it.
            for attachment in replaced { zone.release(attachment) }
            updated[group.zone] = zone
        }
        state.zones.merge(updated) { _, new in new }
        var response = Relay_V1_Response()
        response.save = result
        return response
    }

    private enum SaveOutcome {
        case saved
        /// The current record, nil when there is none.
        case conflict(Zone.Record?)
    }

    /// `replaced` collects the attachment an overwrite stopped referencing.
    private func saveOne(_ item: Relay_V1_SaveItem, into zone: inout Zone, replaced: inout [String]) throws -> SaveOutcome {
        let record = item.record
        let current = zone.records[record.name]
        let live = current.map { !$0.deleted } ?? false
        switch item.expect {
        case .mustNotExist(true) where live:
            return .conflict(current)
        case .expectedSeq(let seq) where current?.seq != seq:
            return .conflict(current)
        default:
            break
        }
        let attachment = record.attachmentID.isEmpty ? nil : record.attachmentID
        if let attachment {
            guard zone.attachments[attachment] != nil else { throw RelayFailure.notFound }
            let held = zone.records.values.contains { !$0.deleted && $0.attachmentID == attachment && $0.name != record.name }
            if held { throw RelayFailure(.conflict, "conflict") }
        }
        zone.lastSeq += 1
        zone.records[record.name] = Zone.Record(
            name: record.name, envelope: record.envelope, modifiedMs: record.clientModifiedAtMs, seq: zone.lastSeq,
            attachmentID: attachment, deleted: false, updatedAt: now
        )
        if live, let old = current?.attachmentID, old != attachment { replaced.append(old) }
        return .saved
    }

    // MARK: - Delete

    /// Worker records.ts `deleteOne`: a mismatched `expected_seq` is a conflict with the current
    /// record; a missing record is a no-op, or a conflict without `current` when a seq was expected;
    /// a tombstone stays as it is.
    func delete(_ op: Relay_V1_Delete, _ session: Session) throws -> Relay_V1_Response {
        try access(op.zone, session, .delete)
        var zone = state.zones[op.zone] ?? Zone()
        var result = Relay_V1_DeleteResult()
        for (index, item) in op.items.enumerated() {
            let current = zone.records[item.name]
            let mismatch = item.hasExpectedSeq && current?.seq != item.expectedSeq
            if mismatch {
                var conflict = Relay_V1_DeleteConflict()
                conflict.index = UInt32(index)
                if let current { conflict.current = Self.proto(current, zone: op.zone, envelope: true) }
                result.conflicts.append(conflict)
                continue
            }
            zone.tombstone(item.name, at: now)
        }
        state.zones[op.zone] = zone
        var response = Relay_V1_Response()
        response.delete = result
        return response
    }

    // MARK: - Changes

    /// README "Operations notes" and "Errors": at most `limit` records (500 when unset or larger)
    /// and 4 MiB of envelopes but at least one; `TOKEN_EXPIRED` above the zone's last seq or
    /// below a purged tombstone. The last page's `new_seq` jumps to the zone's seq.
    func changes(_ op: Relay_V1_Changes, _ session: Session) throws -> Relay_V1_Response {
        try access(op.zone, session, .read)
        let zone = state.zones[op.zone] ?? Zone()
        let since = op.sinceSeq
        if since > zone.lastSeq || (since > 0 && since < zone.floorSeq) {
            throw RelayFailure(.tokenExpired, "token expired")
        }
        let max = op.limit == 0 || op.limit > 500 ? 500 : Int(op.limit)
        var page = Relay_V1_ChangesResult()
        page.newSeq = since
        var count = 0
        var bytes = 0
        for record in zone.records.values.filter({ $0.seq > since }).sorted(by: { $0.seq < $1.seq }) {
            count += 1
            bytes += record.envelope.count
            if count > max || (count > 1 && bytes > state.limits.changesPageBytes) {
                page.more = true
                break
            }
            page.newSeq = record.seq
            if record.deleted {
                page.deleted.append(record.name)
            } else {
                page.changed.append(Self.proto(record, zone: op.zone, envelope: true))
            }
        }
        if !page.more { page.newSeq = Swift.max(page.newSeq, zone.lastSeq) }
        var response = Relay_V1_Response()
        response.changes = page
        return response
    }

    // MARK: - Attachments and readers

    /// README: pair zones take no attachments (`FORBIDDEN`). The upload URL is
    /// `<origin>/v1/blob/<id>`; the attachment counts toward the quota from now on.
    func createUpload(_ op: Relay_V1_CreateUpload, _ session: Session) throws -> Relay_V1_Response {
        let zone = try access(op.zone, session, .save)
        if case .pair = zone { throw RelayFailure.forbidden }
        guard op.size > 0 else { throw RelayFailure.invalid }
        guard op.size <= UInt64(state.limits.maxAttachmentBytes) else {
            throw RelayFailure(.attachmentTooLarge, "attachment too large")
        }
        try checkQuota(op.zone, zone, adding: Int(op.size))
        let id = Self.randomBytes(16).map { String(format: "%02x", $0) }.joined()
        state.zones[op.zone, default: Zone()].attachments[id] = Int(op.size)
        var response = Relay_V1_Response()
        response.upload.attachmentID = id
        response.upload.url = "\(origin)/v1/blob/\(id)"
        response.upload.expiresAtMs = Self.ms(now.addingTimeInterval(RelayTTL.presignedURL))
        return response
    }

    func getDownload(_ op: Relay_V1_GetDownload, _ session: Session) throws -> Relay_V1_Response {
        try access(op.zone, session, .read)
        guard state.zones[op.zone]?.attachments[op.attachmentID] != nil else { throw RelayFailure.notFound }
        var response = Relay_V1_Response()
        response.download.url = "\(origin)/v1/blob/\(op.attachmentID)"
        response.download.expiresAtMs = Self.ms(now.addingTimeInterval(RelayTTL.presignedURL))
        return response
    }

    /// The Mac names the phones that may read its data zone (replacing the list).
    func setHubReaders(_ op: Relay_V1_SetHubReaders, _ session: Session) throws -> Relay_V1_Response {
        guard session.kind == .mac else { throw RelayFailure.forbidden }
        state.zones["data/\(session.deviceID)", default: Zone()].readers = Set(op.phoneDeviceIds)
        return Self.okResponse()
    }

    static func proto(_ record: Zone.Record, zone: String, envelope: Bool) -> Relay_V1_Record {
        var out = Relay_V1_Record()
        out.zone = zone
        out.name = record.name
        if envelope { out.envelope = record.envelope }
        out.clientModifiedAtMs = record.modifiedMs
        out.recordSeq = record.seq
        out.attachmentID = record.attachmentID ?? ""
        out.deleted = record.deleted
        return out
    }
}
