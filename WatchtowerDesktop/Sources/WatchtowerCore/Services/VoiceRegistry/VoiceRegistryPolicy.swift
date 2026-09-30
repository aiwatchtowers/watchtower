/// Every voice-registry threshold in one place (spec §2, Global Constraints).
package enum VoiceRegistryPolicy {
    /// MUST equal the `model_version` literal migration 00080 stamps on
    /// migrated samples.
    package static let embeddingModelVersion = "fluidaudio-wespeaker-v1"
    /// Nearest-sample cosine for a confident match when the recording has an
    /// event (the invited set narrows the candidates).
    package static let confident: Float = 0.70
    /// Stricter confident bar for ad-hoc recordings (no invited set).
    package static let confidentWithoutEvent: Float = 0.75
    /// Minimum gap between the best and the runner-up person.
    package static let margin: Float = 0.10
    /// Below this the cluster is `unknown` rather than `unsure`.
    package static let unsureFloor: Float = 0.55
    /// Self-training: minimum match score to learn an auto sample.
    package static let learn: Float = 0.80
    /// Self-training: the new sample must stay this close to an owner anchor.
    package static let learnAnchorFloor: Float = 0.70
    package static let learnMinSpeechSec: Double = 30
    /// Active auto samples kept per person and channel (oldest retire first).
    package static let autoCapPerChannel = 20
    /// Clusters with less clean speech never match (embedding too noisy).
    package static let minClusterSpeechSec: Double = 20
    package static let clipMinSec: Double = 4
    /// A clip is a quick "whose voice is this" sample, not a passage to sit
    /// through.
    package static let clipMaxSec: Double = 6
    package static let clipsPerCluster = 3
    package static let exportPerChannel = 5
    package static let importConflict: Float = 0.80
    package static let groupMerge: Float = 0.60
    /// Train candidates grouped per reload, newest recordings first — bounds
    /// the live regroup (`VoiceGrouping.group`) on a long history; older
    /// voices come in as newer ones get labeled.
    package static let trainCandidateCap = 400
}
