import Foundation

/// Adaptive gain for the MIC channel only, applied before the recorder's
/// 0.9-weighted tanh mix. On a real 23-minute meeting the owner's mic sat at
/// ~0.008 RMS against ~0.079 RMS of remote (system) audio — 20 dB down, ~6 dB
/// over its own noise floor — so in-room speech was barely intelligible to the
/// transcription engine.
///
/// Deliberately NOT a mix-wide auto-leveler: snoop's normalization of the mixed
/// signal drove it into clipping, which is why the mix uses a tanh soft clip.
/// This raises only the quiet mic term, slowly, with a hard 1–`maxGain` clamp,
/// leaving tanh in place as the safety net.
///
/// Pure (no I/O, no locks) so it is unit-testable; the recorder owns one
/// instance per recording and calls `update` once per IO cycle.
struct MicAGC {
    /// Speech RMS the mic is steered toward (≈ -26 dBFS). Deliberately below
    /// the measured healthy system level (0.079) so a boosted mic never
    /// dominates remote speech in the mix.
    static let target: Float = 0.05
    /// Below this a cycle is silence/room tone: it must not adapt the gain in
    /// either direction, or a quiet stretch would ramp the noise floor up.
    static let noiseFloor: Float = 0.002
    /// +15.6 dB cap. A mic already at a healthy level stays at gain ≈ 1; the
    /// measured 0.008-RMS case lands at 6 → ≈ 0.048, just under `target`.
    static let maxGain: Float = 6

    /// EMA of per-cycle mic RMS over speech-ish cycles; nil until the first one
    /// (seeded with that cycle's RMS, so there is no cold-start spike).
    private var speechEMA: Float?
    private(set) var gain: Float = 1

    /// Feeds one IO cycle's mic RMS. Silence holds the current gain.
    mutating func update(cycleRMS: Float) {
        guard cycleRMS >= Self.noiseFloor else { return }
        let ema = speechEMA.map { 0.05 * cycleRMS + 0.95 * $0 } ?? cycleRMS
        speechEMA = ema
        let desired = min(max(Self.target / max(ema, 0.0005), 1), Self.maxGain)
        // Asymmetric approach: fast to back off (someone leaned into the mic),
        // slow to ramp up (no pumping on ordinary speech pauses).
        gain += (desired - gain) * (desired < gain ? 0.5 : 0.05)
    }
}
