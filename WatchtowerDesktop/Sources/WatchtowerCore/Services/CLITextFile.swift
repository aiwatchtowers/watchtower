import Foundation

/// Ships pasted free text to the CLI as a `--text-file` instead of argv: a
/// large paste would hit ARG_MAX ("Argument list too long" at launch), and
/// argv is readable by any local process through `ps` while the call runs.
/// The file is owner-only and removed when `body` returns or throws.
package enum CLITextFile {
    package static func with<T>(
        _ text: String,
        _ body: (_ path: String) async throws -> T
    ) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchtower-text-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(
            atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url.path)
    }
}
