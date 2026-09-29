import XCTest
@testable import WatchtowerCore

final class SpeakerEmbeddingRegistryFieldsTests: XCTestCase {
    func testLegacyJSONDecodesWithDerivedLabelSource() throws {
        let legacy = #"[{"speaker":"Speaker 2","embedding":[1,0]},{"speaker":"Alice","embedding":[0,1]},{"speaker":"Я","embedding":[1,1]}]"#
        let s = try XCTUnwrap(SpeakerEmbeddings.decode(legacy))
        XCTAssertEqual(s.map(\.effectiveLabelSource), [.none, .owner, .owner])
        XCTAssertNil(s[0].personID)
        XCTAssertEqual(s[0].restoreLabel, "Speaker 2", "a legacy row restores to its current label")
    }

    func testRoundTripKeepsRegistryFieldsWithSnakeCaseKeys() throws {
        var e = SpeakerEmbedding(speaker: "Alice", embedding: [1, 0])
        e.originalLabel = "Speaker 1"
        e.personID = 7
        e.labelSource = .auto
        e.matchedSampleID = 3
        e.channel = .remote
        e.clips = [ClipSpan(start: 1, end: 5)]
        e.speechSec = 42
        e.score = 0.8
        e.modelVersion = VoiceRegistryPolicy.embeddingModelVersion
        let json = try XCTUnwrap(SpeakerEmbeddings.encode([e]))
        XCTAssertTrue(json.contains(#""original_label":"Speaker 1""#))
        XCTAssertTrue(json.contains(#""matched_sample_id":3"#))
        XCTAssertEqual(SpeakerEmbeddings.decode(json)?.first, e)
        XCTAssertEqual(e.effectiveLabelSource, .auto)
        XCTAssertEqual(e.restoreLabel, "Speaker 1")
    }

    func testRejectedPeopleRoundTripAndAreAbsentOnLegacyRows() throws {
        XCTAssertNil(SpeakerEmbeddings.decode(#"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)?.first?.rejectedPersonIDs)

        var e = SpeakerEmbedding(speaker: "Speaker 1", embedding: [1, 0])
        e.rejectPerson(7)
        e.rejectPerson(9)
        e.rejectPerson(7)
        XCTAssertEqual(e.rejectedPersonIDs, [7, 9], "a person is recorded once")
        let json = try XCTUnwrap(SpeakerEmbeddings.encode([e]))
        XCTAssertTrue(json.contains(#""rejected_person_ids":[7,9]"#))
        XCTAssertEqual(SpeakerEmbeddings.decode(json)?.first, e)

        e.clearRejection(of: 7)
        XCTAssertEqual(e.rejectedPersonIDs, [9])
        e.clearRejection(of: 9)
        XCTAssertNil(e.rejectedPersonIDs, "an emptied list goes back to absent")
    }
}
