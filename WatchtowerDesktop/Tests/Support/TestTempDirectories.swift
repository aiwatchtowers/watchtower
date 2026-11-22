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
    /// The process's registry, drained by an `atexit` hook installed on its
    /// first registration.
    package static let shared: TestTempPathRegistry = .init {
        atexit { Self.shared.drain() }
    }

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
        shared.register(path)
    }
}

/// The paths behind `TestTempDirectories`: an instance, so a test can check
/// the exit hook and the drain on a registry of its own.
package final class TestTempPathRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var hookInstalled = false
    private let installExitHook: () -> Void

    /// `installExitHook` runs once, on the first registration.
    package init(installExitHook: @escaping () -> Void) {
        self.installExitHook = installExitHook
    }

    /// Registers a file or directory for removal on `drain`.
    package func register(_ path: String) {
        let install = lock.withLock {
            paths.append(path)
            defer { hookInstalled = true }
            return !hookInstalled
        }
        if install { installExitHook() }
    }

    /// Whether `path` is registered and not yet drained.
    package func isRegistered(_ path: String) -> Bool {
        lock.withLock { paths.contains(path) }
    }

    /// Removes every registered path (a missing one is skipped) and clears
    /// the list.
    package func drain() {
        let toRemove = lock.withLock {
            defer { paths = [] }
            return paths
        }
        let fm = FileManager.default
        for path in toRemove {
            try? fm.removeItem(atPath: path)
        }
    }
}
