import Foundation

/// Shared file-system fixtures for tests that need a real file to exist on
/// disk (e.g. audio-presence checks) without caring about its contents.
package enum TestFixtures {
    /// Creates an empty temp file with a `.caf` extension and returns its
    /// URL. Never cleaned up automatically — call sites needing cleanup do it
    /// themselves (the `VoiceRollbackTests` temp-audio-file precedent).
    package static func tempAudioFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice_registry_test_\(UUID().uuidString).caf")
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw TestFixtureError.fileCreationFailed(url.path)
        }
        return url
    }
}

package enum TestFixtureError: Error {
    case fileCreationFailed(String)
}
