import Foundation

/// The only Swift code that writes `config.yaml` bytes
/// (`ConfigWritersTests.testOnlyConfigFileWriterWritesConfig`). It writes
/// under a live `ConfigFileLock` token for the same path: the new text goes to
/// an owner-only (`0600`, created so — the file holds secrets) sibling first
/// and is renamed over the config, so the config is never readable by others
/// nor half-written.
package enum ConfigFileWriter {
    package enum WriteError: Error, Equatable {
        /// `token` is not a live lock on this config path.
        case notLocked
        case system(Int32)
    }

    package static func writeConfigFile(_ text: String, configPath: String, token: ConfigFileLock.Token) throws {
        guard token.covers(configPath) else { throw WriteError.notLocked }
        let staged = configPath + ".tmp-\(UUID().uuidString)"
        let fd = open(staged, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteError.system(errno) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
            guard rename(staged, configPath) == 0 else { throw WriteError.system(errno) }
        } catch {
            try? FileManager.default.removeItem(atPath: staged)
            throw error
        }
    }
}

/// How a `config.yaml` writer reaches the file: the lock, the read inside it
/// and the write. `live` is the real thing; a test passes a recording of it.
package struct ConfigFileAccess: Sendable {
    package var withLock: @Sendable (_ configPath: String, _ body: (ConfigFileLock.Token) throws -> Void) throws -> Void
    /// The file's bytes, nil when there is no file; throws when it exists but
    /// cannot be read.
    package var read: @Sendable (_ configPath: String) throws -> Data?
    package var writeConfigFile: @Sendable (_ text: String, _ configPath: String, _ token: ConfigFileLock.Token) throws -> Void

    package init(
        withLock: @escaping @Sendable (String, (ConfigFileLock.Token) throws -> Void) throws -> Void,
        read: @escaping @Sendable (String) throws -> Data?,
        writeConfigFile: @escaping @Sendable (String, String, ConfigFileLock.Token) throws -> Void
    ) {
        self.withLock = withLock
        self.read = read
        self.writeConfigFile = writeConfigFile
    }

    package static let live = Self(
        withLock: { path, body in try ConfigFileLock.withLock(configPath: path, body) },
        read: { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        },
        writeConfigFile: { text, path, token in try ConfigFileWriter.writeConfigFile(text, configPath: path, token: token) }
    )
}
