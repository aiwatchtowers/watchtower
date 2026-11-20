import Foundation

/// Temp paths test helpers create, removed when the test process exits.
///
/// Many tests never clean up what a shared helper made for them (a
/// `TestDatabase.createPool` caller without `TestDatabase.cleanup`, a helper
/// called once per shot), and app code can recreate a removed folder from a
/// late async write — so a helper registers each path here at creation and
/// the process removes them all on its way out (`atexit`), whether or not the
/// test cleaned up first. A crashed or killed test process still leaks.
package enum TestTempDirectories {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var exitHookInstalled = false

    /// A new empty directory `<NSTemporaryDirectory()><prefix><uuid>`,
    /// registered for removal at exit.
    package static func make(prefix: String) throws -> String {
        let dir = NSTemporaryDirectory() + prefix + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        register(dir)
        return dir
    }

    /// Registers a file or directory for removal when the process exits.
    package static func register(_ path: String) {
        lock.withLock {
            paths.append(path)
            if !exitHookInstalled {
                exitHookInstalled = true
                atexit { Self.removeRegistered() }
            }
        }
    }

    /// Whether `path` is registered for removal at exit.
    package static func isRegistered(_ path: String) -> Bool {
        lock.withLock { paths.contains(path) }
    }

    /// Removes every path given (a missing one is skipped).
    package static func remove(_ toRemove: [String]) {
        let fm = FileManager.default
        for path in toRemove {
            try? fm.removeItem(atPath: path)
        }
    }

    private static func removeRegistered() {
        let toRemove = lock.withLock {
            defer { paths = [] }
            return paths
        }
        remove(toRemove)
    }
}
