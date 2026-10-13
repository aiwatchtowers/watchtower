import Foundation

/// The phone's file protection classes (mobile E2E D8):
/// - what the background must reach after the first unlock (the replica and the CloudKit transport's store,
///   their directory, the incoming asset stash, sealed recordings, the recordings folder, the hold and its
///   manifest) is
///   `completeUntilFirstUserAuthentication` (class C), set on the directory so every file created in it inherits
///   the class;
/// - plaintext audio (the capture in progress, a finished recording waiting to be sealed) is
///   `completeUnlessOpen`: a capture keeps writing once the phone locks, and nothing new opens it while locked.
///
/// The simulator's file system keeps no protection class (it reads back nil), so tests read back what was set
/// through `observer`; on a device `protection(of:)` reads the real attribute.
enum FileProtection {
    /// Class C: ciphertext, and the hold's manifest (metadata a locked wipe must read).
    static let ciphertext = FileProtectionType.completeUntilFirstUserAuthentication
    static let plaintext = FileProtectionType.completeUnlessOpen

    /// Told every class this task set (tests only; nil in the app).
    @TaskLocal static var observer: (@Sendable (URL, FileProtectionType) -> Void)?

    /// Creates `directory` (with its parents) if needed and sets its class: ciphertext by default.
    static func protectDirectory(_ directory: URL, as type: FileProtectionType = ciphertext) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory, as: type)
    }

    /// Sets the class of an existing file or directory.
    static func protect(_ url: URL, as type: FileProtectionType) throws {
        try FileManager.default.setAttributes([.protectionKey: type], ofItemAtPath: url.path)
        observer?(url, type)
    }

    /// Writes `data` atomically, the new file created in `type` (`ciphertext` or `plaintext`) from the start.
    static func write(_ data: Data, to url: URL, as type: FileProtectionType) throws {
        let protection: Data.WritingOptions = type == plaintext
            ? .completeFileProtectionUnlessOpen
            : .completeFileProtectionUntilFirstUserAuthentication
        try data.write(to: url, options: [.atomic, protection])
        observer?(url, type)
    }

    /// The class the file system reports; nil when it reports none.
    static func protection(of url: URL) throws -> FileProtectionType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
    }
}
