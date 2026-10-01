import XCTest
@testable import WatchtowerCore

final class VoiceLearningTests: XCTestCase {
    private let anchor = VoiceSample(id: 1, personID: 1, embedding: VoicePrintEmbedding.encode([1, 0]),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion, origin: .owner,
                                     anchor: true, status: .active)

    func testLearnsOnlyWhenStrongLongAndAnchored() {
        let strong = VoiceMatcher.Decision.confident(personID: 1, sampleID: 1, score: 0.85)
        XCTAssertTrue(VoiceLearning.shouldLearn(decision: strong, runnerUp: 0.4, embedding: [1, 0.1],
                                                speechSec: 40, anchors: [anchor]))
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: strong, runnerUp: 0.4, embedding: [1, 0.1],
                                                 speechSec: 29, anchors: [anchor]))
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: strong, runnerUp: 0.8, embedding: [1, 0.1],
                                                 speechSec: 40, anchors: [anchor]))
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: strong, runnerUp: 0.4, embedding: [1, 0.1],
                                                 speechSec: 40, anchors: []))
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: .confident(personID: 1, sampleID: 1, score: 0.75),
                                                 runnerUp: 0.2, embedding: [1, 0.1], speechSec: 40, anchors: [anchor]))
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: strong, runnerUp: 0.2, embedding: [0, 1],
                                                 speechSec: 40, anchors: [anchor])) // drifted from anchor
    }

    func testNonConfidentDecisionsAndOtherPeoplesAnchorsNeverLearn() {
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: .unsure(personID: 1, score: 0.9, reason: .unsure),
                                                 runnerUp: 0, embedding: [1, 0], speechSec: 60, anchors: [anchor]))
        XCTAssertFalse(VoiceLearning.shouldLearn(decision: .confident(personID: 2, sampleID: 5, score: 0.9),
                                                 runnerUp: 0, embedding: [1, 0], speechSec: 60, anchors: [anchor]),
                       "an anchor of another person does not vouch for this one")
    }
}
