import Foundation

/// Adaptive gain for the MIC channel only, applied before the recorder's
/// 0.9-weighted tanh mix. On a real 23-minute meeting the owner's mic sat at
/// ~0.008 RMS against ~0.079 RMS of remote (system) audio, so in-room speech
/// was barely intelligible to the transcription engine.
///
/// Deliberately NOT a mix-wide auto-leveler: snoop's normalization of the mixed
/// signal drove it into clipping, which is why the mix uses a tanh soft clip.
/// This raises only the mic term, slowly, hard-clamped to 1–`maxGain`, leaving
/// tanh in place as the safety net.
///
/// **The absolute mic level carries no information about who is speaking.**
/// Replaying an earlier absolute-level-only law over the real
/// `rec_20260807_161845.activity` sidecar showed the mic's own-speech RMS
/// (median 0.0074) sitting *below* the remote audio bleeding into the mic
/// (median 0.0128) — boosting on level alone amplified the bleed to within
/// 5 dB of the direct system stream, i.e. echo. What does separate them is the
/// mic/system RATIO: own speech has a median dominance of 253, bleed a p90 of
/// 0.36. So a cycle is admitted only when the mic *dominates* the system
/// channel (`dominanceFactor`, the same notion as
/// `RoleAssigner.micDominanceFactor`), and every other cycle targets unity —
/// bleed is structurally never boosted.
///
/// Pure (no I/O, no locks) so it is unit-testable; the recorder owns one
/// instance per recording and calls `update` once per IO cycle.
struct MicAGC {
    /// `transcription.micAGC`, default OFF: the dominance-gated law has not yet
    /// been validated end to end on a real recording, so it ships dark and is
    /// opted into for that validation (the `transcription.contextPrompt`
    /// precedent). `defaults` is injectable so tests use an isolated suite.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "transcription.micAGC")
    }

    /// Speech RMS the mic is steered toward (≈ -26 dBFS). Deliberately below
    /// the measured healthy system level (0.079) so a boosted mic never
    /// dominates remote speech in the mix.
    static let target: Float = 0.05
    /// Mic RMS must exceed system RMS by this factor for a cycle to read as
    /// "the owner is speaking" — the same test `RoleAssigner.micDominanceFactor`
    /// applies per 100 ms bin when it looks for the «Я» cluster.
    static let dominanceFactor: Float = 2
    /// Absolute floor below which a cycle is room tone rather than speech.
    /// A plain constant, not a rolling noise estimate: in the measured sidecar
    /// the system-quiet mic histogram has no bimodal gap to track, so an
    /// adaptive floor has nothing to lock onto and merely adds state. Own
    /// speech at 0.008 clears this; room tone (~0.004–0.0075) mostly does not.
    /// Imperfect by design — the dominance gate is the primary defense.
    static let noiseFloor: Float = 0.006
    /// +15.6 dB cap. A mic already at a healthy level stays at gain ≈ 1; the
    /// measured 0.008-RMS case lands at 6 → ≈ 0.048, just under `target`.
    static let maxGain: Float = 6

    /// Wall-clock time constants, converted to a per-cycle factor by `approach`
    /// so the law is independent of the device's IO buffer size (a 512-frame
    /// cycle is ~10.7 ms at 48 kHz, but nothing guarantees that size).
    static let emaTau: TimeInterval = 2      // speech-level average
    static let rampUpTau: TimeInterval = 2   // slow to boost: no pumping
    static let backOffTau: TimeInterval = 0.2 // fast to retreat: someone leaned in

    /// EMA of per-cycle mic RMS over admitted (owner-speech) cycles; nil until
    /// the first one, which seeds it directly so there is no cold-start spike.
    private var speechEMA: Float?
    /// Tracks the owner's speech level across the recording. Held — not decayed
    /// — through bleed and silence, so the owner's next word is already at the
    /// right gain.
    private(set) var speechGain: Float = 1
    /// What the recorder should actually multiply the mic term by for the cycle
    /// just measured: `speechGain` while the owner is speaking, 1 otherwise.
    private(set) var appliedGain: Float = 1

    /// Feeds one IO cycle's mic/system RMS pair. `cycleDuration` is that
    /// cycle's wall-clock length, which sets how far the EMA and the gain move.
    mutating func update(cycleRMS: Float, systemRMS: Float, cycleDuration: TimeInterval) {
        guard cycleRMS.isFinite, systemRMS.isFinite, cycleDuration > 0,
              cycleRMS >= Self.noiseFloor,
              cycleRMS > Self.dominanceFactor * systemRMS
        else {
            // Bleed, room tone, or a nonsense sample: leave the speech state
            // untouched and let the mix glide back to unity. Rejecting
            // non-finite input here also keeps an inf/NaN out of the EMA, which
            // would otherwise stick and silently disable the AGC for the rest
            // of the recording.
            appliedGain = 1
            return
        }
        let ema = speechEMA.map { $0 + (cycleRMS - $0) * Self.approach(tau: Self.emaTau, dt: cycleDuration) }
            ?? cycleRMS
        speechEMA = ema
        // ema >= noiseFloor by construction (it is a convex combination of
        // admitted cycles), so the division needs no epsilon guard.
        let desired = min(max(Self.target / ema, 1), Self.maxGain)
        let tau = desired < speechGain ? Self.backOffTau : Self.rampUpTau
        speechGain += (desired - speechGain) * Self.approach(tau: tau, dt: cycleDuration)
        appliedGain = speechGain
    }

    /// Fraction of the remaining distance to cover in `dt` for an exponential
    /// approach with time constant `tau`.
    private static func approach(tau: TimeInterval, dt: TimeInterval) -> Float {
        Float(1 - exp(-dt / tau))
    }
}
