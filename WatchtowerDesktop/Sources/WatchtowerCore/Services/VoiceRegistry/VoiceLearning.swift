/// Spec §2.4 + invariant 1: self-train only from strong, long,
/// anchor-consistent matches — an auto sample can never drift a person's
/// voice away from what the owner confirmed.
package enum VoiceLearning {
    package static func shouldLearn(
        decision: VoiceMatcher.Decision,
        runnerUp: Float,
        embedding: [Float],
        speechSec: Double,
        anchors: [VoiceSample]
    ) -> Bool {
        guard case let .confident(personID, _, score) = decision,
              score >= VoiceRegistryPolicy.learn,
              score - runnerUp >= VoiceRegistryPolicy.margin,
              speechSec >= VoiceRegistryPolicy.learnMinSpeechSec else { return false }
        return anchors.contains {
            $0.personID == personID && $0.anchor && $0.status == .active
                && $0.modelVersion == VoiceRegistryPolicy.embeddingModelVersion
                && (VoiceMatcher.cosine(embedding, $0.vector) ?? -1) >= VoiceRegistryPolicy.learnAnchorFloor
        }
    }
}
