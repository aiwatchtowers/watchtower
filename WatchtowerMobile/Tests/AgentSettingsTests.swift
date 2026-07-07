import Security
import XCTest
import WatchtowerKit
@testable import WatchtowerMobile

/// Task 6 (Plan 5): the BYOK key/model plumbing in the APP target —
/// `APIKeyStore` round-trips through the device Keychain, `AppEnvironment`
/// exposes `hasAPIKey` (flipped only by its save/remove methods) and a
/// UserDefaults-persisted `agentModel`, and the @Sendable providers handed to
/// `DirectAPIAgent` read LIVE state (never a snapshot captured at init — the
/// no-capture rule from the Task 5 review). Paranoia pin: the saved key lives
/// in the Keychain ONLY — never in environment state or UserDefaults.
@MainActor
final class AgentSettingsTests: XCTestCase {
    /// Obviously-fake marker value; unique enough to grep leak surfaces for.
    private static let testKey = "sk-ant-test-agent-settings-3f9a1c"

    override func setUp() {
        super.setUp()
        Self.resetPersistedState()
    }

    override func tearDown() {
        Self.resetPersistedState()
        super.tearDown()
    }

    /// Keychain + UserDefaults outlive the process — every test starts and
    /// ends with both blank so no state leaks between tests (or into the app
    /// itself, which shares this simulator's keychain).
    private nonisolated static func resetPersistedState() {
        try? APIKeyStore().remove()
        UserDefaults.standard.removeObject(forKey: "agent.model")
    }

    // MARK: - Fixtures

    private func makeEnvironment() throws -> AppEnvironment {
        try AppEnvironment(transport: InMemoryCloudTransport(), replicaPath: makeReplicaPath())
    }

    /// Isolated on-disk pool path (the production DatabasePool mechanism).
    private func makeReplicaPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-agent-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("replica.sqlite").path
    }

    // MARK: - APIKeyStore round-trip

    /// save → read → overwrite → remove → read-nil; remove is idempotent.
    func testKeyRoundTripSaveReadRemove() throws {
        let store = APIKeyStore()
        XCTAssertNil(store.read(), "clean slate — no key stored yet")

        try store.save(Self.testKey)
        XCTAssertEqual(store.read(), Self.testKey)

        try store.save("sk-ant-test-replacement")
        XCTAssertEqual(store.read(), "sk-ant-test-replacement", "save must overwrite, not duplicate")

        try store.remove()
        XCTAssertNil(store.read())
        XCTAssertNoThrow(try store.remove(), "removing an absent key is a no-op, not an error")
    }

    /// The REAL Keychain services the store on this simulator — a raw
    /// SecItem read (bypassing `APIKeyStore`) sees the saved key under the
    /// pinned service name, proving the DEBUG in-memory fallback stayed
    /// dormant. Skips (not fails) on an entitlement-less host, where the
    /// fallback is the documented behavior.
    func testRealKeychainBacksTheStoreOnSimulator() throws {
        try APIKeyStore().save(Self.testKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "watchtower.mobile.anthropic-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try XCTSkipIf(status == errSecMissingEntitlement, "entitlement-less test host — in-memory fallback in play")
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual((item as? Data).flatMap { String(data: $0, encoding: .utf8) }, Self.testKey)
    }

    // MARK: - AppEnvironment observable state

    /// `hasAPIKey` flips on save/remove (the only mutation paths) and a fresh
    /// environment reads the truth from the Keychain at init.
    func testHasAPIKeyFlipsOnSaveAndRemove() throws {
        let env = try makeEnvironment()
        XCTAssertFalse(env.hasAPIKey)

        try env.saveAPIKey(Self.testKey)
        XCTAssertTrue(env.hasAPIKey)
        XCTAssertTrue(try makeEnvironment().hasAPIKey, "a fresh environment must see the stored key at init")

        try env.removeAPIKey()
        XCTAssertFalse(env.hasAPIKey)
        XCTAssertNil(APIKeyStore().read(), "removeAPIKey must clear the Keychain item itself")
    }

    /// Model choice defaults to sonnet and survives an environment relaunch
    /// via UserDefaults (Decision 6 — a model NAME is not a secret).
    func testAgentModelPersistsAcrossEnvironments() throws {
        let env = try makeEnvironment()
        XCTAssertEqual(env.agentModel, .sonnet5, "spec fixes sonnet as the mobile default")

        env.agentModel = .haiku45
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "agent.model"), AgentModel.haiku45.rawValue,
            "the choice must persist under the stable key"
        )
        XCTAssertEqual(try makeEnvironment().agentModel, .haiku45, "a fresh environment must restore the choice")
    }

    // MARK: - The closures handed to DirectAPIAgent (no-capture rule)

    /// The providers wired into `DirectAPIAgent` must reflect changes made
    /// AFTER the environment (and thus the agent) was built: they read the
    /// Keychain / UserDefaults live on every call. A closure that captured
    /// @MainActor state at init would freeze the nil key forever.
    func testAgentProvidersReadLiveStateAfterInit() throws {
        let env = try makeEnvironment()
        XCTAssertNil(AppEnvironment.liveAPIKey(), "no key yet")
        XCTAssertEqual(AppEnvironment.liveAgentModel(), .sonnet5)

        // Saved AFTER the agent was constructed — the provider must see it.
        try env.saveAPIKey(Self.testKey)
        XCTAssertEqual(AppEnvironment.liveAPIKey(), Self.testKey)

        env.agentModel = .opus48
        XCTAssertEqual(AppEnvironment.liveAgentModel(), .opus48)

        try env.removeAPIKey()
        XCTAssertNil(AppEnvironment.liveAPIKey(), "removal must be live too")
    }

    /// The wired agent consults the live (empty) Keychain: with no key saved,
    /// `sendTurn` throws `missingKey` before any side effect — the Kit's own
    /// suite proves the no-rows part; here we pin the APP's wiring.
    func testDirectAgentSendTurnWithoutKeyThrowsMissingKey() async throws {
        let env = try makeEnvironment()
        do {
            _ = try await env.directAgent.sendTurn(text: "hello?", sessionID: nil)
            XCTFail("sendTurn must throw without a stored key")
        } catch let error as DirectAPIAgentError {
            XCTAssertEqual(error, .missingKey)
        }
    }

    // MARK: - Paranoia pin: the key lives in the Keychain ONLY

    /// The saved key must never surface in any rendering of environment
    /// state, nor in the UserDefaults slot that persists the model choice.
    func testSavedKeyNeverAppearsInEnvironmentStateOrModelStorage() throws {
        let env = try makeEnvironment()
        try env.saveAPIKey(Self.testKey)
        env.agentModel = .haiku45

        XCTAssertFalse(String(describing: env).contains(Self.testKey))
        XCTAssertFalse(String(reflecting: env).contains(Self.testKey))
        for child in Mirror(reflecting: env).children {
            XCTAssertFalse(
                String(describing: child.value).contains(Self.testKey),
                "key leaked into AppEnvironment.\(child.label ?? "?")"
            )
        }

        let storedModel = UserDefaults.standard.string(forKey: "agent.model")
        XCTAssertEqual(storedModel, AgentModel.haiku45.rawValue)
        XCTAssertFalse(storedModel?.contains(Self.testKey) ?? false, "the model slot must never carry the key")
    }
}
