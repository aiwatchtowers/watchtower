import Foundation

/// Per-100 ms mic/system RMS timeline captured alongside a recording as a
/// `rec_X.activity` sidecar. The mic and system signals exist separately only
/// inside the recorder's IO callback — this file preserves that "is the owner
/// speaking" signal so the diarization post-pass can label one speaker
/// cluster as «Я». Losing the sidecar only loses that label, never a failure.
struct MicActivity: Equatable {
    static let binDuration: Double = 0.1

    struct Bin: Equatable {
        let mic: Float
        let sys: Float
    }

    let bins: [Bin]

    /// rec_X.caf → rec_X.activity: the rec_ prefix keeps the sidecar inside
    /// the Go daemon's orphan-sweep contract (cleanupOrphanRecordings), so it
    /// is deleted alongside the audio after the retention window.
    static func url(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("activity")
    }

    /// nil when the sidecar is missing, unreadable, or holds no valid bins.
    static func load(for audioURL: URL) -> MicActivity? {
        guard let text = try? String(contentsOf: url(for: audioURL), encoding: .utf8) else { return nil }
        let bins: [Bin] = text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let mic = Float(parts[0]), let sys = Float(parts[1]) else { return nil }
            return Bin(mic: mic, sys: sys)
        }
        guard !bins.isEmpty else { return nil }
        return MicActivity(bins: bins)
    }

    /// RMS pair at `timeSec`; nil outside the recorded timeline.
    func bin(at timeSec: Double) -> Bin? {
        guard timeSec >= 0 else { return nil }
        let index = Int(timeSec / Self.binDuration)
        return index < bins.count ? bins[index] : nil
    }
}

/// Accumulates per-frame mic/system samples into 100 ms RMS bins and renders
/// completed bins as sidecar lines. Pure (no I/O) so it is unit-testable; the
/// recorder drains `flushLines()` on its write queue. The trailing partial
/// bin is simply dropped at stop — a <100 ms tail carries no role signal.
struct MicActivityAccumulator {
    private let samplesPerBin: Int
    private var micSquares: Double = 0
    private var sysSquares: Double = 0
    private var count = 0
    private var pendingLines: [String] = []

    init(sampleRate: Double) {
        samplesPerBin = max(1, Int(sampleRate * MicActivity.binDuration))
    }

    mutating func add(mic: Float, sys: Float) {
        micSquares += Double(mic * mic)
        sysSquares += Double(sys * sys)
        count += 1
        if count == samplesPerBin {
            let micRMS = (micSquares / Double(count)).squareRoot()
            let sysRMS = (sysSquares / Double(count)).squareRoot()
            pendingLines.append(String(format: "%.6f %.6f", micRMS, sysRMS))
            micSquares = 0
            sysSquares = 0
            count = 0
        }
    }

    mutating func flushLines() -> [String] {
        defer { pendingLines = [] }
        return pendingLines
    }
}
