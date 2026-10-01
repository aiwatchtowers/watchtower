import Foundation

/// Watches the system (call) channel of a meeting recording, one ~100 ms
/// RMS value at a time, for a long stretch with no call audio after the
/// call had been heard. The system-audio tap can go silent mid-meeting (an
/// output-device switch, the call app changing process). Nothing failed:
/// the transcript just quietly lost the other side, and Whisper filled the
/// mic-only room tone with hallucinations. A call where everyone stays quiet
/// for minutes looks the same in the levels, so this only reports the
/// silence ("no call audio since …") and never decides why it happened.
///
/// Pure and incremental, counting in bins. The recorder center feeds it the
/// live level stream to warn during capture, and `gaps(system:)` replays a
/// saved `rec_X.activity` sidecar to annotate a finished recording — one
/// detector, so the two apply the same rules. Live level pairs can run a
/// little longer than 100 ms (one IO buffer more), so the live warning may
/// come somewhat after the nominal two minutes.
package struct CallAudioWatch {
    /// Below this RMS the system channel carries nothing a person could hear
    /// (a dead tap writes exact zeros; a live call's quietest stretch sits
    /// well above it).
    package static let silenceFloor: Float = 0.0001
    /// A silent stretch this long counts as a gap.
    package static let minGapSec: Double = 120
    /// A gap can only start right after the call was being heard: at least
    /// `recentAudioSec` of call audio within the preceding
    /// `recentWindowSec`. A room-only meeting whose system channel carries
    /// just the odd notification never qualifies.
    package static let recentAudioSec: Double = 30
    package static let recentWindowSec: Double = 300
    /// A gap ends once the call is back: `resumeRunSec` of unbroken call
    /// audio (a reply — a notification sound or a click is shorter), or
    /// `resumeSec` of it within the last `resumeWindowSec` (choppy speech
    /// from an app that gates silence between words).
    package static let resumeRunSec: Double = 2
    package static let resumeSec: Double = 5
    package static let resumeWindowSec: Double = 10

    package struct Gap: Equatable, Sendable {
        package let startSec: Double
        /// nil while the gap is still open at the end of the input.
        package let endSec: Double?

        package init(startSec: Double, endSec: Double?) {
            self.startSec = startSec
            self.endSec = endSec
        }
    }

    private let binSec: Double
    /// `audioBefore[i]` = bins of call audio among the first `i` bins.
    private var audioBefore: [Int] = [0]
    /// First silent bin of the current silent stretch, once one qualifies.
    private var silentFrom: Int?
    /// Bins of unbroken call audio up to now.
    private var heardRun = 0
    private var closedGaps: [Gap] = []

    package init(binSec: Double = 0.1) {
        self.binSec = binSec
    }

    private var bins: Int { audioBefore.count - 1 }

    /// Call-audio seconds in the last `seconds` (up to now).
    private func audioSec(inLast seconds: Double) -> Double {
        let span = min(bins, Int((seconds / binSec).rounded()))
        return Double(audioBefore[bins] - audioBefore[bins - span]) * binSec
    }

    /// Feeds the next ~`binSec` RMS value of the system channel.
    package mutating func add(system: Float) {
        let index = bins
        let heard = system >= Self.silenceFloor
        if !heard, silentFrom == nil, audioSec(inLast: Self.recentWindowSec) >= Self.recentAudioSec {
            silentFrom = index
        }
        audioBefore.append(audioBefore[index] + (heard ? 1 : 0))
        heardRun = heard ? heardRun + 1 : 0
        guard heard, let from = silentFrom,
              Double(heardRun) * binSec >= Self.resumeRunSec || audioSec(inLast: Self.resumeWindowSec) >= Self.resumeSec
        else { return }
        // Call audio is back. The stretch ended where the returning audio
        // began (the first audio bin of the resume window); a long enough
        // stretch is recorded as a gap.
        let windowStart = max(from, bins - Int((Self.resumeWindowSec / binSec).rounded()))
        let end = (windowStart..<bins).first { audioBefore[$0 + 1] > audioBefore[$0] } ?? index
        if Double(end - from) * binSec >= Self.minGapSec {
            closedGaps.append(Gap(startSec: Double(from) * binSec, endSec: Double(end) * binSec))
        }
        silentFrom = nil
    }

    /// The gap the recording is in right now (open-ended), if any.
    package var openGap: Gap? {
        guard let from = silentFrom, Double(bins - from) * binSec >= Self.minGapSec else { return nil }
        return Gap(startSec: Double(from) * binSec, endSec: nil)
    }

    /// Every gap so far, closed ones first, then the open one.
    package var gaps: [Gap] { closedGaps + (openGap.map { [$0] } ?? []) }

    /// True when the system channel carried no call audio at all (a
    /// room-only meeting, or a tap that never worked).
    package var neverHeardCall: Bool { audioBefore[bins] == 0 }

    /// Replays a whole recording's system levels.
    package static func gaps(system: [Float], binSec: Double = 0.1) -> [Gap] {
        var watch = Self(binSec: binSec)
        system.forEach { watch.add(system: $0) }
        return watch.gaps
    }
}
