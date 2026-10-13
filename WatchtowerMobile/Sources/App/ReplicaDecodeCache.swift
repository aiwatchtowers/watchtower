import Foundation
import WatchtowerSync

/// One observation's decoded replica values, kept while their kind's change
/// stamp holds (`ReplicaStore.kindVersions`, board #724): a read whose
/// stamp is unchanged returns the stored value without touching the
/// payloads, so a write of another kind decodes nothing here. Owned by the
/// model, so it survives the observation's restarts (an error, a resume
/// from the background) and a restart re-decodes only what changed.
///
/// Stamps are per replica file: a cache must not outlive its store (each
/// model is built with its environment's store and never switches).
final class ReplicaDecodeCache: @unchecked Sendable {
    private struct Entry {
        let version: Int64
        let value: Any
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var decodeCounts: [String: Int] = [:]

    /// The value stored under `key` for `version`, else `decode()`'s
    /// (stored for the next read). Decodes outside the lock.
    func value<T>(_ key: String, version: Int64, decode: () throws -> T) rethrows -> T {
        let hit = lock.withLock { entries[key] }
        if let hit, hit.version == version, let value = hit.value as? T {
            return value
        }
        let value = try decode()
        lock.withLock {
            entries[key] = Entry(version: version, value: value)
            decodeCounts[key, default: 0] += 1
        }
        return value
    }

    /// The decodes run under `key` so far (the tests' decode counter).
    func decodes(_ key: String) -> Int {
        lock.withLock { decodeCounts[key] ?? 0 }
    }
}
