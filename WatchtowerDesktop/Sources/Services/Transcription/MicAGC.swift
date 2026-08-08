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
/// 0.36. So the EMA adapts only on cycles where the mic *dominates* the system
/// channel (`dominanceFactor`).
///
/// **Deciding per cycle is not the same as applying per cycle.** A dominance
/// test evaluated on every ~10 ms buffer flickers within a single word —
/// vowels pass, consonants and short gaps fail — and switching the applied gain
/// with it amplitude-modulates the owner's own speech at syllable rate (the
/// replay measured 1.68 unity↔boost flips per second, with 36.6% of dominant
/// bins mixed at 1x while their neighbours were boosted). So the apply-gate is
/// separate from the adapt-gate: an admitted cycle arms a `holdSec` window, an
/// unambiguous bleed cycle releases it at once, and anything in between coasts
/// on the held gain. This is the same aggregation `RoleAssigner` performs — its
/// per-bin predicate is identical, and where it aggregates by majority SHARE
/// across a segment, the AGC aggregates TEMPORALLY through the hold.
///
/// Pure (no I/O, no locks) so it is unit-testable; the recorder owns one
/// instance per recording and calls `update` once per IO cycle.
struct MicAGC {
    /// `transcription.micAGC`, default OFF: the dominance-gated law has not yet
    /// been validated end to end on a real recording, so it ships dark and is
    /// opted into for that validation (the `transcription.contextPrompt`
    /// precedent, PR #79). `defaults` is injectable so tests use an isolated suite.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "transcription.micAGC")
    }

    /// Speech RMS the mic is steered toward (≈ -26 dBFS). Deliberately below
    /// the measured healthy system level (0.079) so a boosted mic never
    /// dominates remote speech in the mix.
    static let target: Float = 0.05
    /// Mic RMS must exceed system RMS by this factor for a cycle to read as
    /// "the owner is speaking" — the same per-bin test
    /// `RoleAssigner.micDominanceFactor` applies when it looks for the «Я»
    /// cluster.
    static let dominanceFactor: Float = 2
    /// Absolute floor below which a cycle is room tone rather than speech.
    /// A plain constant, not a rolling noise estimate: in the measured sidecar
    /// the system-quiet mic histogram has no bimodal gap to track, so an
    /// adaptive floor has nothing to lock onto and merely adds state.
    ///
    /// The floor is porous on purpose. Quiet room-tone-shaped bins do clear it
    /// and dilute the EMA, so on the measured recording the gain converges to
    /// ~3.2–3.9 rather than the ~6 a speech-only EMA would ask for, and boosted
    /// own speech lands at ~0.036–0.066 instead of exactly on `target`. That
    /// bias is the safe direction — under-boosting costs some headroom, while
    /// over-boosting bakes clipping and amplified bleed into the `.caf` that is
    /// the source of truth. The dominance gate, not this floor, is the primary
    /// defense.
    static let noiseFloor: Float = 0.006
    /// +15.6 dB cap on the boost.
    static let maxGain: Float = 6

    /// How long an admitted cycle keeps the gain applied after it. Covers the
    /// consonants, stops and breath gaps inside a phrase (the replay's flip
    /// rate falls from 2338 to 350 transitions — one per ~4 s — at 1 s, and
    /// own-speech p10 rises from 0.0043 to 0.0111) while still being far
    /// shorter than a conversational turn.
    static let holdSec: TimeInterval = 1.0

    /// Wall-clock time constants, converted to a per-cycle factor by `approach`
    /// so the law is independent of the device's IO buffer size (a 512-frame
    /// cycle is ~10.7 ms at 48 kHz, but nothing guarantees that size).
    static let emaTau: TimeInterval = 2      // speech-level average
    static let rampUpTau: TimeInterval = 2   // slow to boost: no pumping
    static let backOffTau: TimeInterval = 0.2 // fast to retreat: someone leaned in

    /// EMA of per-cycle mic RMS over admitted (owner-speech) cycles; nil until
    /// the first one, which seeds it directly so there is no cold-start spike.
    private var speechEMA: Float?
    /// Time left on the hold armed by the last admitted cycle.
    private var holdRemaining: TimeInterval = 0
    /// Tracks the owner's speech level across the recording. Held — not decayed
    /// — through bleed and silence, so the owner's next word is already at the
    /// right gain.
    private(set) var speechGain: Float = 1
    /// What the recorder should actually multiply the mic term by for the cycle
    /// just measured.
    private(set) var appliedGain: Float = 1

    /// Feeds one IO cycle's mic/system RMS pair. `cycleDuration` is that
    /// cycle's wall-clock length, which sets how far the EMA and the gain move
    /// and how much hold the cycle consumes.
    mutating func update(cycleRMS: Float, systemRMS: Float, cycleDuration: TimeInterval) {
        // A non-finite reading must never reach the EMA: it would stick there
        // and silently disable the AGC for the rest of the recording.
        let measured = cycleRMS.isFinite && systemRMS.isFinite && cycleDuration > 0

        if measured, cycleRMS >= Self.noiseFloor, cycleRMS > Self.dominanceFactor * systemRMS {
            adapt(cycleRMS: cycleRMS, cycleDuration: cycleDuration)
            appliedGain = speechGain
            holdRemaining = Self.holdSec
            return
        }
        if measured, systemRMS > Self.dominanceFactor * cycleRMS {
            // Unambiguous remote audio. This is the case the whole design
            // exists to keep at unity, so it cancels the hold outright rather
            // than coasting through it.
            appliedGain = 1
            holdRemaining = 0
            return
        }
        // Ambiguous: sub-floor room tone, near-threshold double-talk, or the
        // consonants and gaps inside a phrase. Coast on the held gain until the
        // window runs out.
        if measured {
            holdRemaining = max(0, holdRemaining - cycleDuration)
        }
        appliedGain = holdRemaining > 0 ? speechGain : 1
    }

    private mutating func adapt(cycleRMS: Float, cycleDuration: TimeInterval) {
        let ema = speechEMA.map { $0 + (cycleRMS - $0) * Self.approach(tau: Self.emaTau, dt: cycleDuration) }
            ?? cycleRMS
        speechEMA = ema
        // ema >= noiseFloor by construction (it is a convex combination of
        // admitted cycles), so the division needs no epsilon guard.
        let desired = min(max(Self.target / ema, 1), Self.maxGain)
        let tau = desired < speechGain ? Self.backOffTau : Self.rampUpTau
        speechGain += (desired - speechGain) * Self.approach(tau: tau, dt: cycleDuration)
    }

    /// Per-frame ramp from the previous cycle's gain to this one's, so a gain
    /// change is spread over the cycle instead of stepping between two adjacent
    /// samples. `frameCount` must be positive (the recorder drops empty cycles).
    static func glide(from: Float, to: Float, frameCount: Int) -> (start: Float, step: Float) {
        (from, (to - from) / Float(frameCount))
    }

    /// Fraction of the remaining distance to cover in `dt` for an exponential
    /// approach with time constant `tau`.
    private static func approach(tau: TimeInterval, dt: TimeInterval) -> Float {
        Float(1 - exp(-dt / tau))
    }
}
