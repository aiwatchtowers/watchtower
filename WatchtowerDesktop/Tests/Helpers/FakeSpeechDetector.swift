import Foundation
@testable import WatchtowerDesktop

/// Speech = the runs of non-zero samples, so a test draws speech by writing
/// non-zero values. Counts its calls; throws when `error` is set.
final class FakeSpeechDetector: SpeechDetector, @unchecked Sendable {
    var error: Error?
    private let lock = NSLock()
    private var callCount = 0

    var calls: Int { lock.withLock { callCount } }

    func speechRanges(in samples: [Float]) async throws -> [Range<Int>] {
        lock.withLock { callCount += 1 }
        if let error { throw error }
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, sample) in samples.enumerated() {
            if sample != 0, start == nil { start = index }
            if sample == 0, let open = start {
                ranges.append(open..<index)
                start = nil
            }
        }
        if let open = start { ranges.append(open..<samples.count) }
        return ranges
    }
}
