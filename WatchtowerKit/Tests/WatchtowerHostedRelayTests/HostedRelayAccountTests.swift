import Foundation
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import WatchtowerSync
import XCTest

/// `HostedRelayAccount` (relay client Phase 4, Task 2) on the fake: the stored account id,
/// the account state, `submit_transaction` (README "Subscriptions") and `register_push`.
final class HostedRelayAccountTests: HostedRelayScenarioCase {
    private static let group = "TEAM.com.example.app"

    private struct Phone {
        let client: HostedRelayClient
        let keychain: AccountTestKeychain
        let account: HostedRelayAccount
    }

    private var relay: FakeHostedRelay {
        get throws { try requireFake("needs the fake's billing, clock and push log (fake only)") }
    }

    private var clock: ManualRelayClock {
        get throws { try XCTUnwrap(manualClock) }
    }

    /// A phone that has not registered; the account registers it on first use.
    private func phone(
        seed: UInt8, wrapHTTP: ((any RelayHTTP) -> any RelayHTTP)? = nil, keychain: AccountTestKeychain = AccountTestKeychain()
    ) async throws -> Phone {
        let client = try await makeClient(kind: .phone, seed: seed, register: false, wrapHTTP: wrapHTTP)
        let identity = KeychainRelayIdentity(backend: keychain, group: Self.group)
        return Phone(client: client, keychain: keychain, account: HostedRelayAccount(session: HostedRelaySession(client: client), identity: identity))
    }

    private func jws(_ id: UUID, original: String = "1000", signed: Date? = nil) throws -> String {
        FakeHostedRelay.fakeJWS(
            originalTransactionID: original, appAccountToken: id.uuidString, signedDate: try signed ?? clock.now())
    }

    private func registers() -> Int {
        backend.opLog.filter { if case .register = $0 { true } else { false } }.count
    }

    private func submitOps() -> Int {
        backend.opLog.filter { if case .submitTransaction = $0 { true } else { false } }.count
    }

    private func assertRefusal(
        _ expected: RelaySubmitRefusal, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("no refusal, expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RelaySubmitRefusal, expected, "\(error)", file: file, line: line)
        }
    }

    // MARK: - Account id

    func testAccountIDRegistersOnceAndIsKept() async throws {
        let phone = try await phone(seed: 40)
        let first = try await phone.account.accountID()
        let second = try await phone.account.accountID()
        let again = try await HostedRelayAccount(
            session: HostedRelaySession(client: phone.client),
            identity: KeychainRelayIdentity(backend: phone.keychain, group: Self.group)
        ).accountID()

        XCTAssertEqual([first, second, again], [first, first, first])
        XCTAssertEqual(registers(), 1, "one register while an id is stored")
        let stored = try await stand.accountID(ofPhone: phone.client.deviceID)
        XCTAssertEqual(first.uuidString.lowercased(), stored)
        XCTAssertEqual(phone.keychain.adds.map(\.account), ["relay.account"])
        let call = try XCTUnwrap(phone.keychain.adds.first)
        XCTAssertEqual(call.access, .afterFirstUnlock)
        XCTAssertEqual(call.group, Self.group)
        XCTAssertTrue(call.dataProtection)
    }

    func testALockedKeychainCreatesNoAccountItem() async throws {
        let phone = try await phone(seed: 41)
        phone.keychain.isLocked = true

        do {
            _ = try await phone.account.accountID()
            XCTFail("a locked Keychain must throw")
        } catch {
            XCTAssertEqual(error as? KeyStoreError, .locked)
        }
        phone.keychain.isLocked = false
        XCTAssertNil(phone.keychain.item("relay.account"), "nothing was created")
        XCTAssertEqual(registers(), 0, "no relay call before the Keychain answered")
    }

    func testAnAccountIDThatIsNoUUIDIsRefused() async throws {
        let phone = try await phone(seed: 42, wrapHTTP: RewritingAccountHTTP.init)

        await assertRelayError(.undecodable(status: 200)) { _ = try await phone.account.accountID() }
        XCTAssertNil(phone.keychain.item("relay.account"), "a refused id is never stored")
    }

    // MARK: - State

    func testStateReadsEntitlementMovedAndSlots() async throws {
        let phone = try await phone(seed: 43)
        let id = try await phone.account.accountID()
        let none = try await phone.account.state()
        XCTAssertEqual(none, RelayAccountState(entitlement: .none, until: nil, moved: false, macs: []))
        XCTAssertFalse(none.paying)

        let kinds: [(String, RelayAccountState.Entitlement, Bool)] = [
            ("active", .active, true), ("grace", .grace, true), ("expired", .expired, false), ("revoked", .revoked, false)
        ]
        for (name, kind, paying) in kinds {
            try await stand.setEntitlement(accountID: id.uuidString.lowercased(), state: name, for: .seconds(86_400))
            let state = try await phone.account.state()
            XCTAssertEqual(state.entitlement, kind, name)
            XCTAssertEqual(state.paying, paying, name)
            XCTAssertEqual(state.until, try clock.now().addingTimeInterval(86_400), name)
        }

        try await stand.setEntitlement(accountID: id.uuidString.lowercased(), state: "active", for: .seconds(86_400))
        let mac = try await makeClient(kind: .mac, seed: 44)
        try await stand.pair(mac: mac.deviceID, phones: [phone.client.deviceID])
        let slotted = try await phone.account.state()
        XCTAssertEqual(slotted.macs, [mac.deviceID])
        XCTAssertFalse(slotted.moved)
    }

    // MARK: - submit

    func testAPurchaseActivatesTheAccount() async throws {
        let phone = try await phone(seed: 45)
        let id = try await phone.account.accountID()

        let entitlement = try await phone.account.submit(jws: try jws(id))

        XCTAssertEqual(entitlement, .active)
        let state = try await phone.account.state()
        XCTAssertTrue(state.paying)
        XCTAssertNotNil(state.until)
    }

    func testARestoreOnANewPhoneMovesTheSubscription() async throws {
        let old = try await phone(seed: 46)
        let new = try await phone(seed: 47)
        let oldID = try await old.account.accountID()
        let newID = try await new.account.accountID()
        _ = try await old.account.submit(jws: try jws(oldID))
        _ = try relay.takeEvents(for: old.client.deviceID)
        try clock.advance(by: .seconds(60))

        // StoreKit keeps the first purchase's token on a restore.
        let entitlement = try await new.account.submit(jws: try jws(oldID))

        XCTAssertEqual(entitlement, .active)
        let moved = try relay.takeEvents(for: old.client.deviceID).compactMap { event -> Relay_V1_ControlKind? in
            if case .control(let control) = event.kind { return control.kind }
            return nil
        }
        XCTAssertEqual(moved, [.subscriptionMoved])
        let oldState = try await old.account.state()
        XCTAssertTrue(oldState.moved)
        XCTAssertEqual(oldState.entitlement, .none)
        let newState = try await new.account.state()
        XCTAssertTrue(newState.paying)
        XCTAssertNotEqual(newID, oldID)
    }

    func testAStaleRestoreIsRefused() async throws {
        let old = try await phone(seed: 48)
        let new = try await phone(seed: 49)
        let oldID = try await old.account.accountID()
        _ = try await new.account.accountID()
        _ = try await old.account.submit(jws: try jws(oldID))
        try clock.advance(by: .seconds(20 * 60))

        await assertRefusal(.invalidTransaction) {
            _ = try await new.account.submit(jws: try jws(oldID, signed: try clock.now().addingTimeInterval(-11 * 60)))
        }
        let state = try await old.account.state()
        XCTAssertTrue(state.paying, "nothing moved")
    }

    func testAFourthMoveInThirtyDaysIsRefused() async throws {
        let first = try await phone(seed: 50)
        let second = try await phone(seed: 51)
        let firstID = try await first.account.accountID()
        _ = try await second.account.accountID()
        _ = try await first.account.submit(jws: try jws(firstID))

        for holder in [second, first, second] {
            try clock.advance(by: .seconds(60))
            _ = try await holder.account.submit(jws: try jws(firstID))
        }
        try clock.advance(by: .seconds(60))
        await assertRefusal(.transferLimit) { _ = try await first.account.submit(jws: try jws(firstID)) }
        let state = try await second.account.state()
        XCTAssertTrue(state.paying, "the refused move changed nothing")
    }

    func testASubmitNeverDowngrades() async throws {
        let phone = try await phone(seed: 52)
        let id = try await phone.account.accountID()
        try await stand.setEntitlement(accountID: id.uuidString.lowercased(), state: "grace", for: .seconds(3 * 86_400))
        let before = try await phone.account.state()

        let entitlement = try await phone.account.submit(jws: try jws(id))

        XCTAssertEqual(entitlement, .grace, "a grace account stays in grace")
        let after = try await phone.account.state()
        XCTAssertEqual(after, before)
    }

    func testSubmitRetriesWhileTheRevocationIsDelivered() async throws {
        let relay = try relay
        let old = try await phone(seed: 53)
        let new = try await phone(seed: 54)
        let oldID = try await old.account.accountID()
        _ = try await new.account.accountID()
        _ = try await old.account.submit(jws: try jws(oldID))
        let mac = try await makeClient(kind: .mac, seed: 55)
        try await stand.pair(mac: mac.deviceID, phones: [old.client.deviceID])
        relay.holdRevocations = true
        try clock.advance(by: .seconds(60))
        let payload = try jws(oldID)
        let ops = submitOps()

        let call = Task { try await new.account.submit(jws: payload) }
        await (try clock).waitForSleepers(1)
        relay.markRevocationsDelivered()
        try clock.advance(by: .milliseconds(500))
        let entitlement = try await call.value

        XCTAssertEqual(entitlement, .active)
        XCTAssertEqual(submitOps() - ops, 2, "one answer UNAVAILABLE, one retry")
        let state = try await new.account.state()
        XCTAssertEqual(state.macs, [mac.deviceID], "the retry did not move it twice")
    }

    func testNoBillingIsNotImplemented() async throws {
        let relay = try relay
        let phone = try await phone(seed: 56)
        let id = try await phone.account.accountID()
        relay.billingConfigured = false

        await assertRefusal(.notImplemented) { _ = try await phone.account.submit(jws: try jws(id)) }
    }

    func testTheRelaysReadableFiveHundredIsUnreachable() async throws {
        let failing = FailingSubmitHTTP()
        let phone = try await phone(seed: 61, wrapHTTP: failing.wrapping)
        let id = try await phone.account.accountID()
        failing.isFailing = true

        // Worker `http/op.ts`: a failed dispatch is HTTP 500 with a readable UNSPECIFIED error.
        await assertRefusal(.unreachable) { _ = try await phone.account.submit(jws: try jws(id)) }
    }

    func testARestoreFromALapsedHolderActivatesTheCaller() async throws {
        let old = try await phone(seed: 62)
        let new = try await phone(seed: 63)
        let oldID = try await old.account.accountID()
        _ = try await new.account.accountID()
        _ = try await old.account.submit(jws: try jws(oldID))
        try await stand.setEntitlement(accountID: oldID.uuidString.lowercased(), state: "expired", for: .seconds(86_400))
        try clock.advance(by: .seconds(60))

        let entitlement = try await new.account.submit(jws: try jws(oldID))

        XCTAssertEqual(entitlement, .active, "a live transaction activates, whatever the old holder was")
        let state = try await new.account.state()
        XCTAssertTrue(state.paying)
    }

    func testARestoreNeverDowngradesAPayingCaller() async throws {
        let old = try await phone(seed: 64)
        let new = try await phone(seed: 65)
        let oldID = try await old.account.accountID()
        let newID = try await new.account.accountID()
        _ = try await old.account.submit(jws: try jws(oldID))
        try await stand.setEntitlement(accountID: oldID.uuidString.lowercased(), state: "expired", for: .seconds(86_400))
        try await stand.setEntitlement(accountID: newID.uuidString.lowercased(), state: "grace", for: .seconds(86_400))
        _ = try relay.takeEvents(for: new.client.deviceID)
        try clock.advance(by: .seconds(60))

        let entitlement = try await new.account.submit(jws: try jws(oldID))

        XCTAssertEqual(entitlement, .grace)
        let controls = try relay.takeEvents(for: new.client.deviceID).compactMap { event -> Relay_V1_ControlKind? in
            if case .control(let control) = event.kind { return control.kind }
            return nil
        }
        XCTAssertFalse(controls.contains(.entitlementExpired), "the caller never lapsed")
    }

    // MARK: - register_push

    func testRegisterPushIsSentWithItsEnvironment() async throws {
        let relay = try relay
        let phone = try await phone(seed: 57)
        _ = try await phone.account.accountID()

        try await phone.account.registerPush(token: "ab12cd34", environment: .sandbox)
        try await phone.account.registerPush(token: "ab12cd35", environment: .production)

        XCTAssertEqual(relay.pushRegistrations.map(\.token), ["ab12cd34", "ab12cd35"])
        XCTAssertEqual(relay.pushRegistrations.map(\.environment), [.sandbox, .production])
        XCTAssertEqual(Set(relay.pushRegistrations.map(\.phoneDeviceID)), [phone.client.deviceID])
    }

    func testARefusedTokenIsAnError() async throws {
        let relay = try relay
        let phone = try await phone(seed: 58)
        _ = try await phone.account.accountID()

        await assertRelayError(.server(code: .unspecified, retryAfter: nil)) {
            try await phone.account.registerPush(token: "not hex", environment: .sandbox)
        }
        XCTAssertEqual(relay.pushRegistrations, [])
    }

    // MARK: - Secrets

    func testNoMessageReachesAnError() async throws {
        let relay = try relay
        let phone = try await phone(seed: 59)
        let id = try await phone.account.accountID()
        let payload = try jws(id)
        var errors: [any Error] = []
        do { _ = try await phone.account.submit(jws: "garbage") } catch { errors.append(error) }
        relay.billingConfigured = false
        do { _ = try await phone.account.submit(jws: payload) } catch { errors.append(error) }
        relay.billingConfigured = true
        _ = try await phone.account.submit(jws: payload)
        let other = try await self.phone(seed: 60)
        let otherID = try await other.account.accountID()
        for index in 0..<3 {
            try clock.advance(by: .seconds(60))
            let holder = index.isMultiple(of: 2) ? other : phone
            _ = try await holder.account.submit(jws: try jws(id))
        }
        try clock.advance(by: .seconds(60))
        do { _ = try await phone.account.submit(jws: try jws(id)) } catch { errors.append(error) }
        XCTAssertNotEqual(otherID, id)

        XCTAssertEqual(errors.compactMap { $0 as? RelaySubmitRefusal }, [.invalidTransaction, .notImplemented, .transferLimit])
        for error in errors {
            let text = [String(describing: error), "\(error)", error.localizedDescription].joined(separator: "|").lowercased()
            for message in ["invalid transaction", "not implemented", "transfer limit", "garbage", payload.lowercased()] {
                XCTAssertFalse(text.contains(message), "\(message) in \(text)")
            }
        }
    }
}

/// Answers `submit_transaction` with the relay's real failure: HTTP 500, a readable UNSPECIFIED error.
private final class FailingSubmitHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false

    var isFailing: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func wrapping(_ inner: any RelayHTTP) -> any RelayHTTP {
        Wrapper(owner: self, inner: inner)
    }

    private struct Wrapper: RelayHTTP {
        let owner: FailingSubmitHTTP
        let inner: any RelayHTTP

        func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data) {
            if owner.isFailing, let request = try? Relay_V1_Request(serializedBytes: body), case .submitTransaction? = request.op {
                var response = Relay_V1_Response()
                response.id = request.id
                response.error.code = .unspecified
                response.error.message = "internal error"
                return (500, try response.serializedData())
            }
            return try await inner.post(url, body: body, headers: headers)
        }

        func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int {
            try await inner.put(url, file: file, headers: headers)
        }

        func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int {
            try await inner.get(url, to: file, maxBytes: maxBytes, headers: headers)
        }
    }
}

/// Rewrites the relay's `registered` answer so its account id is no UUID.
private struct RewritingAccountHTTP: RelayHTTP {
    let inner: any RelayHTTP

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let (status, data) = try await inner.post(url, body: body, headers: headers)
        guard var response = try? Relay_V1_Response(serializedBytes: data), case .registered = response.result else { return (status, data) }
        response.registered.accountID = "not-a-uuid"
        return (status, try response.serializedData())
    }

    func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int {
        try await inner.put(url, file: file, headers: headers)
    }

    func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int {
        try await inner.get(url, to: file, maxBytes: maxBytes, headers: headers)
    }
}

/// An in-memory `KeychainBackend` that records its adds and can be locked.
final class AccountTestKeychain: KeychainBackend, @unchecked Sendable {
    struct Add {
        let account: String
        let group: String?
        let access: KeyAccess
        let dataProtection: Bool
    }

    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var added: [Add] = []
    private var locked = false

    var adds: [Add] { lock.withLock { added } }

    var isLocked: Bool {
        get { lock.withLock { locked } }
        set { lock.withLock { locked = newValue } }
    }

    func item(_ account: String) -> Data? {
        lock.withLock { items[account] }
    }

    func read(account: String, group: String?) throws -> Data? {
        try lock.withLock {
            if locked { throw KeyStoreError.locked }
            return items[account]
        }
    }

    func write(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws {
        try lock.withLock {
            if locked { throw KeyStoreError.locked }
            items[account] = data
        }
    }

    func add(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws -> Bool {
        try lock.withLock {
            if locked { throw KeyStoreError.locked }
            added.append(Add(account: account, group: group, access: access, dataProtection: dataProtection))
            guard items[account] == nil else { return false }
            items[account] = data
            return true
        }
    }

    func delete(account: String, group: String?) throws {
        try lock.withLock {
            if locked { throw KeyStoreError.locked }
            items[account] = nil
        }
    }
}
