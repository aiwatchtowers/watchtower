import Foundation
@testable import WatchtowerDesktop

/// A model download held until the test releases it.
@MainActor
final class HeldDownload {
    private(set) var calls = 0
    private var release: CheckedContinuation<Void, Never>?

    func hold(_: String, _: String, _ progress: @escaping @Sendable (Double) -> Void) async throws {
        calls += 1
        progress(0.25)
        await withCheckedContinuation { release = $0 }
        if let failWith {
            self.failWith = nil
            throw failWith
        }
    }

    var isHeld: Bool { release != nil }

    /// Set before `finish()`: the held call throws it instead of returning.
    var failWith: Error?

    func finish() {
        release?.resume()
        release = nil
    }
}

extension TranscriptionModelProvisioner {
    /// A provisioner on `download` that never looks at the real caches.
    static func forTests(
        _ download: HeldDownload,
        defaults: UserDefaults,
        label: String = "Test model",
        downloadsModel: @escaping (ModelKey) -> Bool = { _ in true }
    ) -> TranscriptionModelProvisioner {
        TranscriptionModelProvisioner(
            downloadFn: { try await download.hold($0, $1, $2) },
            describe: { _ in (label: label, sizeBytes: nil) },
            downloadsModel: downloadsModel,
            filesMissing: { _ in false },
            defaults: defaults)
    }
}
