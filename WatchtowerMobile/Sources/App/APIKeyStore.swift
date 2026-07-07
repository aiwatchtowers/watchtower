import Foundation
import os
import Security

/// A SecItem call failed with an unexpected status. The raw `OSStatus` is all
/// the context there is — the key itself never appears in an error.
struct APIKeyStoreError: Error, Equatable {
    let status: OSStatus
}

/// Keychain home of the user's Anthropic API key (Plan 5 Design Decision 5).
///
/// Lives in the APP target so WatchtowerKit stays keychain-free and testable:
/// the Kit's `DirectAPIAgent` takes an `apiKey: @Sendable () -> String?`
/// closure that reads through this store on every call (see
/// `AppEnvironment.liveAPIKey`).
///
/// One generic-password item — service `watchtower.mobile.anthropic-key`,
/// `kSecAttrAccessibleAfterFirstUnlock` so a backgrounded answer can still
/// read the key after a reboot's first unlock, but never from a
/// never-unlocked device. The key must NEVER be persisted anywhere else
/// (UserDefaults, replica DB, logs) — `AgentSettingsTests` pins that.
///
/// TEST-PROCESS FALLBACK (DEBUG builds only): an unsigned test host can lack
/// the keychain entitlement, in which case every SecItem call fails with
/// `errSecMissingEntitlement` (-34018). ONLY on that exact status do DEBUG
/// builds fall back to a process-local in-memory store, so the suite still
/// exercises the store's semantics. The production path is ALWAYS the real
/// Keychain — Release builds compile with no fallback at all.
///
/// OBSERVED on this project's simulator setup: because the dev build is
/// unsigned (`CODE_SIGNING_ALLOWED=NO` until packaging entitlements land),
/// the whole app process lacks the keychain entitlement and the fallback
/// services BOTH tests and the dev-simulator app — a key saved there lives
/// only until the process exits (first engagement is os_log'ed). Signed
/// builds (real devices, TestFlight) always hit the real Keychain.
struct APIKeyStore: Sendable {
    private static let service = "watchtower.mobile.anthropic-key"

    /// The stored key, or nil when none is stored (or it cannot be decoded).
    func read() -> String? {
        var query = Self.itemQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        #if DEBUG
        if status == errSecMissingEntitlement { return MemoryFallback.shared.value }
        #endif
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the key, replacing any previous one (delete-then-add — one
    /// write path instead of an add/update fork).
    func save(_ key: String) throws {
        let deleteStatus = SecItemDelete(Self.itemQuery() as CFDictionary)
        #if DEBUG
        if deleteStatus == errSecMissingEntitlement {
            MemoryFallback.shared.value = key
            return
        }
        #endif
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw APIKeyStoreError(status: deleteStatus)
        }
        var attributes = Self.itemQuery()
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        #if DEBUG
        // Symmetry with read/remove: a host could plausibly allow delete of
        // a nonexistent item yet reject add without entitlements.
        if status == errSecMissingEntitlement {
            MemoryFallback.shared.value = key
            return
        }
        #endif
        guard status == errSecSuccess else {
            throw APIKeyStoreError(status: status)
        }
    }

    /// Deletes the stored key. Removing an absent key is a no-op, not an
    /// error — "make sure no key remains" is the operation callers mean.
    func remove() throws {
        let status = SecItemDelete(Self.itemQuery() as CFDictionary)
        #if DEBUG
        if status == errSecMissingEntitlement {
            MemoryFallback.shared.value = nil
            return
        }
        #endif
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError(status: status)
        }
    }

    /// The class+service pair identifying OUR item — the base of every query.
    /// (A function, not a stored `[String: Any]` static: that type is not
    /// Sendable and would poison this Sendable struct.)
    private static func itemQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }
}

#if DEBUG
/// See `APIKeyStore`'s type doc: DEBUG-only stand-in used exclusively when
/// SecItem reports `errSecMissingEntitlement` (entitlement-less test host).
/// Process-local, so round-trip semantics still hold within one test run.
private final class MemoryFallback: @unchecked Sendable {
    static let shared = MemoryFallback()
    private let lock = NSLock()
    private var stored: String?
    private var announced = false

    var value: String? {
        get { lock.withLock { announce(); return stored } }
        set { lock.withLock { announce(); stored = newValue } }
    }

    /// One notice per process so the log tells WHICH store serviced the key.
    /// Must be called with `lock` held.
    private func announce() {
        guard !announced else { return }
        announced = true
        Logger(subsystem: "WatchtowerMobile", category: "APIKeyStore")
            .notice("keychain entitlement missing — DEBUG in-memory key store engaged (key will not outlive the process)")
    }
}
#endif
