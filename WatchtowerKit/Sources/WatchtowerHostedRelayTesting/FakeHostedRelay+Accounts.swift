import Foundation
import WatchtowerHostedRelay
import WatchtowerRelayProto

/// A phone's account: entitlement, Mac slots, pairing slots and the revocation
/// journal (README "Slots", "Subscriptions", "Control events"; Worker `do/account/*`).
extension FakeHostedRelay {
    struct Account {
        struct Revocation {
            let macID: String
            let at: Date
            var delivered = false
        }

        struct Pairing {
            let slotID: String
            let macID: String
            let expiresAt: Date
        }

        let id: String
        let phoneID: String
        var entitlement: Relay_V1_EntitlementKind = .none
        var until: Date?
        /// When the account entered `expired`: reading stays allowed for 7 days from then.
        var expiredAt: Date?
        /// The subscription moved to another phone (README `get_account_state`).
        var moved = false
        var macs: Set<String> = []
        /// User removals and replacements, for the 30-day replacement rule.
        var removals: [Date] = []
        var replacements: [Date] = []
        var revocations: [Revocation] = []
        var pairings: [String: Pairing] = [:]
        /// The phone's pending vouches: hub id → expiry (README "Vouched hubs"; not backed up).
        var vouches: [String: Date] = [:]

        var paying: Bool {
            entitlement == .active || entitlement == .grace
        }

        /// Paying, or expired within the read window (Worker `accountReadable`).
        func readable(at now: Date) -> Bool {
            if paying { return true }
            guard entitlement == .expired, let expiredAt else { return false }
            return now < expiredAt.addingTimeInterval(RelayTTL.postExpiryRead)
        }
    }

    func runAccountOp(_ op: Relay_V1_Request.OneOf_Op, _ session: Session) throws -> Relay_V1_Response {
        switch op {
        case .addSlot(let add):
            try addSlot(macID: add.macDeviceID, by: requirePhone(session), vouch: .required)
            return Self.okResponse()
        case .removeSlot(let remove):
            return try removeSlot(remove, session)
        case .openPairing(let open):
            return try openPairing(macID: open.macDeviceID, by: requirePhone(session))
        case .closePairing(let close):
            return try closePairing(slotID: close.slotID, session)
        case .promotePairing(let promote):
            try promotePairing(slotID: promote.slotID, by: requirePhone(session))
            return Self.okResponse()
        case .registerPush(let push):
            return try registerPush(push, session)
        case .sendAlert(let alert):
            return try sendAlert(alert, session)
        case .submitTransaction:
            _ = try requirePhone(session)
            throw RelayFailure(.unspecified, "not implemented")
        case .getAccountState:
            return accountState(session)
        case .vouchHub(let vouch):
            return try vouchHub(vouch, session)
        default:
            throw RelayFailure.invalid
        }
    }

    /// The session's phone account id; `FORBIDDEN` for a Mac.
    private func requirePhone(_ session: Session) throws -> String {
        guard session.kind == .phone, let id = state.devices[session.deviceID]?.accountID else { throw RelayFailure.forbidden }
        return id
    }

    func accountOfPhone(_ phoneID: String) -> String? {
        state.devices[phoneID]?.accountID
    }

    // MARK: - Vouched hubs

    /// Whether a slot add needs the phone's pending vouch (Worker `VouchMode`): `required` for the
    /// phone's `add_slot` and `promote_pairing`, `operator` for the stand's `/dev/pair`.
    enum VouchMode {
        case required
        case `operator`
    }

    /// README "Vouched hubs" `vouch_hub`, the six checks in their order: a phone (`FORBIDDEN`), paying
    /// (`ENTITLEMENT_INACTIVE`), the attestation (`ATTESTATION_REQUIRED` / `ATTESTATION_FAILED`), a
    /// registered hub with that key (`NOT_FOUND`), room in the slots unless the hub holds one
    /// (`SLOT_LIMIT`). `Ok` keeps (or renews) the pending vouch for 10 minutes.
    private func vouchHub(_ op: Relay_V1_VouchHub, _ session: Session) throws -> Relay_V1_Response {
        let accountID = try requirePhone(session)
        guard var account = state.accounts[accountID], account.paying else { throw RelayFailure.entitlementInactive }
        try checkVouchAttestation(op, phoneID: session.deviceID)
        guard RelayAuthMessages.deviceID(publicKey: op.authPub) == op.hubDeviceID,
              let hub = state.devices[op.hubDeviceID], hub.kind == .mac, hub.authPub == op.authPub
        else { throw RelayFailure.notFound }
        guard account.macs.contains(hub.id) || account.macs.count < state.limits.maxMacSlots else {
            throw RelayFailure(.slotLimit, "slot limit")
        }
        let now = now
        account.vouches = account.vouches.filter { $0.value > now }
        account.vouches[hub.id] = now.addingTimeInterval(RelayTTL.vouch)
        state.accounts[accountID] = account
        return Self.okResponse()
    }

    /// README "Vouched hubs" (Worker `unvouchedAllowed`, `refuseUnvouched`): a Mac in no account's
    /// slots may only read its account state, close a pairing, send `vouch_hub` (to get its own
    /// `FORBIDDEN`) and use pair zones (every item of a non-empty save); else `HUB_NOT_VOUCHED`.
    /// As the Worker's `vouched()` (the gate closes with snapshot delivery), a Mac whose removal is
    /// not delivered yet still counts as vouched.
    func refuseUnvouched(_ op: Relay_V1_Request.OneOf_Op, _ session: Session) throws {
        let id = session.deviceID
        let vouched = state.accounts.values.contains { account in
            account.macs.contains(id) || account.revocations.contains { $0.macID == id && !$0.delivered }
        }
        guard session.kind == .mac, !vouched else { return }
        let pair = { (zone: String) in zone.hasPrefix("pair/") }
        let allowed: Bool
        switch op {
        case .getAccountState, .subscribe, .closePairing, .vouchHub:
            allowed = true
        case .save(let save):
            allowed = !save.items.isEmpty && save.items.allSatisfy { pair($0.record.zone) }
        case .delete(let delete):
            allowed = pair(delete.zone)
        case .changes(let changes):
            allowed = pair(changes.zone)
        default:
            allowed = false
        }
        guard allowed else { throw RelayFailure(.hubNotVouched, "hub not vouched") }
    }

    // MARK: - Slots

    /// README `add_slot`: a paying account, a registered Mac (else `NOT_FOUND`), idempotent; a new
    /// Mac needs the phone's unexpired vouch (`HUB_NOT_VOUCHED`) unless `vouch` is `.operator`, and
    /// takes it only when the add succeeds; at most `maxMacSlots` (`SLOT_LIMIT`); a new Mac added
    /// within 30 days of a removal is a replacement, at most `slotReplacementsPer30Days` of them
    /// (`SLOT_REPLACEMENT_LIMIT`).
    func addSlot(macID: String, by accountID: String, vouch: VouchMode) throws {
        guard var account = state.accounts[accountID], account.paying else { throw RelayFailure.entitlementInactive }
        if account.macs.contains(macID) { return }
        guard state.devices[macID]?.kind == .mac else { throw RelayFailure.notFound }
        if vouch == .required {
            guard let expiry = account.vouches[macID], now < expiry else { throw RelayFailure(.hubNotVouched, "hub not vouched") }
            account.vouches[macID] = nil
        }
        guard account.macs.count < state.limits.maxMacSlots else { throw RelayFailure(.slotLimit, "slot limit") }
        let windowStart = now.addingTimeInterval(-RelayTTL.replacementWindow)
        if account.removals.contains(where: { $0 > windowStart }) {
            guard account.replacements.filter({ $0 > windowStart }).count < state.limits.slotReplacementsPer30Days else {
                throw RelayFailure(.slotReplacementLimit, "slot replacement limit")
            }
            account.replacements.append(now)
        }
        account.macs.insert(macID)
        state.accounts[accountID] = account
    }

    /// README "Slots (`remove_slot`)": by the phone or the Mac itself. The revocation is
    /// remembered 24 h and a repeat answers `Ok`; with `holdRevocations` it answers
    /// `UNAVAILABLE` until `markRevocationsDelivered()`. `NOT_FOUND` when the Mac has no slot
    /// and no recent revocation. The phone loses its place among the Mac's hub readers
    /// (Worker `zone.ts`, R34): only a new `set_hub_readers` restores it.
    private func removeSlot(_ op: Relay_V1_RemoveMacSlot, _ session: Session) throws -> Relay_V1_Response {
        guard session.deviceID == op.phoneDeviceID || session.deviceID == op.macDeviceID else { throw RelayFailure.forbidden }
        guard !op.phoneDeviceID.isEmpty, let accountID = accountOfPhone(op.phoneDeviceID),
              var account = state.accounts[accountID]
        else { throw RelayFailure.notFound }
        let since = now.addingTimeInterval(-RelayTTL.revocationMemory)
        account.revocations.removeAll { $0.at <= since }
        defer { state.accounts[accountID] = account }
        if account.macs.remove(op.macDeviceID) != nil {
            account.removals.append(now)
            account.revocations.append(Account.Revocation(macID: op.macDeviceID, at: now, delivered: !state.holdRevocations))
            dropHubReader(account.phoneID, of: op.macDeviceID)
            sendControl(.slotRemoved, op.macDeviceID, to: account.phoneID)
            sendControl(.slotRemoved, account.phoneID, to: op.macDeviceID)
            return Self.okResponse()
        }
        let recent = account.revocations.filter { $0.macID == op.macDeviceID }
        guard !recent.isEmpty else { throw RelayFailure.notFound }
        guard recent.allSatisfy(\.delivered) else { throw RelayFailure(.unavailable, "unavailable") }
        return Self.okResponse()
    }

    /// Marks every remembered revocation as delivered: a repeated `remove_slot` answers `Ok` from now on.
    public func markRevocationsDelivered() {
        locked {
            for (id, account) in state.accounts {
                state.accounts[id]?.revocations = account.revocations.map { revocation in
                    var delivered = revocation
                    delivered.delivered = true
                    return delivered
                }
            }
        }
    }

    // MARK: - Pairing

    /// Worker `pairing.ts`: a paying phone opens a 600 s slot for a registered Mac, replacing
    /// its previous slot for that Mac; `PAIRING_OPENED` (detail: the slot id) goes to the Mac.
    private func openPairing(macID: String, by accountID: String) throws -> Relay_V1_Response {
        guard var account = state.accounts[accountID], account.paying else { throw RelayFailure.entitlementInactive }
        guard state.devices[macID]?.kind == .mac else { throw RelayFailure.notFound }
        account.pairings = account.pairings.filter { $0.value.macID != macID }
        let slotID = SlotIDBase32.encode(Self.randomBytes(16))
        let pairing = Account.Pairing(slotID: slotID, macID: macID, expiresAt: now.addingTimeInterval(RelayTTL.pairingSlot))
        account.pairings[slotID] = pairing
        state.accounts[accountID] = account
        sendControl(.pairingOpened, slotID, to: macID)
        var response = Relay_V1_Response()
        response.pairingSlot.slotID = slotID
        response.pairingSlot.expiresAtMs = Self.ms(pairing.expiresAt)
        return response
    }

    /// The phone closes in its own account, the Mac a pairing that names it.
    private func closePairing(slotID: String, _ session: Session) throws -> Relay_V1_Response {
        guard !slotID.isEmpty, let (accountID, pairing) = pairing(slotID: slotID) else { throw RelayFailure.notFound }
        let phoneID = state.accounts[accountID]?.phoneID
        guard session.deviceID == phoneID || session.deviceID == pairing.macID else { throw RelayFailure.notFound }
        state.accounts[accountID]?.pairings[slotID] = nil
        return Self.okResponse()
    }

    /// An open slot becomes a Mac slot (`add_slot` rules); an expired one is `PAIRING_EXPIRED` and stays.
    private func promotePairing(slotID: String, by accountID: String) throws {
        guard let pairing = state.accounts[accountID]?.pairings[slotID] else { throw RelayFailure.notFound }
        guard now < pairing.expiresAt else { throw RelayFailure(.pairingExpired, "pairing expired") }
        try addSlot(macID: pairing.macID, by: accountID, vouch: .required)
        state.accounts[accountID]?.pairings[slotID] = nil
    }

    /// The account holding pairing slot `slotID`.
    func pairing(slotID: String) -> (String, Account.Pairing)? {
        for account in state.accounts.values {
            if let pairing = account.pairings[slotID] { return (account.id, pairing) }
        }
        return nil
    }

    // MARK: - Push, alerts, account state

    private func registerPush(_ op: Relay_V1_RegisterPushToken, _ session: Session) throws -> Relay_V1_Response {
        _ = try requirePhone(session)
        let hex = op.token.count.isMultiple(of: 2) && op.token.allSatisfy(\.isHexDigit)
        guard op.env != .unspecified, !op.token.isEmpty, op.token.count <= 200, hex else { throw RelayFailure.invalid }
        state.pushPhones.insert(session.deviceID)
        return Self.okResponse()
    }

    /// Worker `push.ts` `alertSender`: the phone's account must slot the Mac (`FORBIDDEN`) and pay
    /// (`ENTITLEMENT_INACTIVE`), the phone must read the Mac's data zone (`FORBIDDEN`), the alert must
    /// fit a 4096-byte push (`RECORD_TOO_LARGE`), and the phone needs a push token (`NOT_FOUND`).
    /// No push is sent.
    private func sendAlert(_ op: Relay_V1_SendAlert, _ session: Session) throws -> Relay_V1_Response {
        guard session.kind == .mac else { throw RelayFailure.forbidden }
        guard let accountID = accountOfPhone(op.phoneDeviceID), let account = state.accounts[accountID],
              account.macs.contains(session.deviceID)
        else { throw RelayFailure.forbidden }
        guard account.paying else { throw RelayFailure.entitlementInactive }
        guard state.zones["data/\(session.deviceID)"]?.readers.contains(op.phoneDeviceID) == true else { throw RelayFailure.forbidden }
        let body = #"{"aps":{"mutable-content":1,"alert":{"title":"Watchtower"}},"e":""# + op.envelope.base64EncodedString() + #""}"#
        guard body.utf8.count <= 4_096 else { throw RelayFailure(.recordTooLarge, "record too large") }
        guard state.pushPhones.contains(op.phoneDeviceID) else { throw RelayFailure.notFound }
        return Self.okResponse()
    }

    /// R34: a phone whose account no longer slots the Mac leaves the Mac's hub readers.
    private func dropHubReader(_ phoneID: String, of macID: String) {
        state.zones["data/\(macID)"]?.readers.remove(phoneID)
    }

    /// README `get_account_state`: a phone's entitlement, `moved` and slots; a Mac's slot holders.
    private func accountState(_ session: Session) -> Relay_V1_Response {
        var response = Relay_V1_Response()
        if session.kind == .phone, let id = accountOfPhone(session.deviceID), let account = state.accounts[id] {
            response.accountState.entitlement.state = account.entitlement
            response.accountState.entitlement.untilMs = account.until.map(Self.ms) ?? 0
            response.accountState.moved = account.moved
            response.accountState.macDeviceIds = account.macs.sorted()
        } else {
            response.accountState.phones = state.accounts.values
                .filter { $0.macs.contains(session.deviceID) }
                .sorted { $0.phoneID < $1.phoneID }
                .map { account in
                    var holder = Relay_V1_SlotHolder()
                    holder.phoneDeviceID = account.phoneID
                    holder.paying = account.paying
                    return holder
                }
        }
        return response
    }

    // MARK: - Entitlement

    /// Worker `applyEntitlement`: entering expired stamps `expiredAt`, a paying state clears it;
    /// leaving a paying state sends `ENTITLEMENT_EXPIRED` to the phone (empty detail) and to
    /// every slotted Mac (detail: the phone's device id).
    func applyEntitlement(_ next: Relay_V1_EntitlementKind, until: Date?, to accountID: String) {
        guard var account = state.accounts[accountID] else { return }
        let wasPaying = account.paying
        let lapsed: (Relay_V1_EntitlementKind) -> Bool = { $0 == .expired || $0 == .revoked }
        if lapsed(next), !lapsed(account.entitlement) { account.expiredAt = now }
        account.entitlement = next
        account.until = until
        if account.paying {
            account.expiredAt = nil
            account.moved = false
        }
        state.accounts[accountID] = account
        guard wasPaying, !account.paying else { return }
        sendControl(.entitlementExpired, "", to: account.phoneID)
        for mac in account.macs.sorted() { sendControl(.entitlementExpired, account.phoneID, to: mac) }
    }

    /// The subscription of `fromPhone` moves to `toPhone` (README "Subscriptions": the App Store
    /// path, which the fake does not run), as Worker `account.ts` `moved` + `slots.ts` `adoptSlotsTx`:
    /// the old account's pairings close, its slots are revoked (remembered 24 h like
    /// `remove_slot`, no replacement counted, no `SLOT_REMOVED`), it reports `moved` with no
    /// entitlement, and its phone gets `SUBSCRIPTION_MOVED`. The new account takes the
    /// entitlement and adopts the Macs in id order up to the slot limit; its phone reads a Mac's
    /// data zone only after the Mac names it a reader again (re-pairing by QR).
    public func moveSubscription(fromPhone: String, toPhone: String) throws {
        try locked {
            guard let fromID = accountOfPhone(fromPhone), let toID = accountOfPhone(toPhone), fromID != toID,
                  var from = state.accounts[fromID]
            else { throw RelayStandError.notFound }
            let entitlement = from.entitlement
            let until = from.until
            let macs = from.macs.sorted()
            for mac in macs {
                from.revocations.append(Account.Revocation(macID: mac, at: now, delivered: !state.holdRevocations))
                dropHubReader(fromPhone, of: mac)
            }
            from.macs = []
            from.pairings = [:]
            from.entitlement = .none
            from.until = nil
            from.expiredAt = nil
            from.moved = true
            state.accounts[fromID] = from
            sendControl(.subscriptionMoved, "", to: fromPhone)
            applyEntitlement(entitlement, until: until, to: toID)
            for mac in macs where state.accounts[toID].map({ $0.macs.count < state.limits.maxMacSlots }) == true {
                state.accounts[toID]?.macs.insert(mac)
            }
        }
    }
}

extension FakeHostedRelay: RelayStandControl {
    public func setEntitlement(accountID: String, state name: String, for duration: Duration) async throws {
        let states: [String: Relay_V1_EntitlementKind] = ["active": .active, "grace": .grace, "expired": .expired, "revoked": .revoked]
        guard let next = states[name] else { throw RelayStandError.invalid }
        let paying = next == .active || next == .grace
        guard duration >= .zero, !paying || duration > .zero else { throw RelayStandError.invalid }
        try locked {
            guard let account = state.accounts[accountID] else { throw RelayStandError.notFound }
            let until = duration > .zero ? now.addingTimeInterval(Self.seconds(duration)) : account.until
            applyEntitlement(next, until: until, to: accountID)
        }
    }

    public func accountID(ofPhone phoneID: String) async throws -> String {
        try locked {
            guard let id = accountOfPhone(phoneID) else { throw RelayStandError.notFound }
            return id
        }
    }

    public func pair(mac: String, phones: [String]) async throws {
        try locked {
            for phone in phones {
                guard let accountID = accountOfPhone(phone) else { throw RelayStandError.notFound }
                do {
                    try addSlot(macID: mac, by: accountID, vouch: .operator)
                } catch let failure as RelayFailure {
                    throw failure.code == .notFound ? RelayStandError.notFound : RelayStandError.refused(failure.code)
                }
            }
            state.zones["data/\(mac)", default: Zone()].readers = Set(phones)
        }
    }

    public func expireMailboxes(_ zones: [String], elapsed: Duration) async throws {
        try locked {
            for zone in zones {
                guard case .mailbox = ZoneName(zone) else { throw RelayStandError.invalid }
            }
            let now = now
            for zone in zones {
                expireMailbox(zone, before: now.addingTimeInterval(Self.seconds(elapsed) - RelayTTL.mailbox)) { _ in now }
            }
        }
    }
}

/// Lower-case unpadded RFC 4648 base32: slot ids (Worker `newSlotId`, 16 bytes → 26 characters).
enum SlotIDBase32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    static func encode(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)]) }
        return out
    }
}
