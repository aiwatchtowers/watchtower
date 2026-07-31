import XCTest
@testable import WatchtowerDesktop

final class RoleAssignerTests: XCTestCase {

    private func seg(_ text: String, _ start: Double, _ end: Double, lang: String = "ru") -> TranscriptSegment {
        TranscriptSegment(text: text, startSec: start, endSec: end, language: lang)
    }

    private func spk(_ id: String, _ start: Double, _ end: Double) -> SpeakerSegment {
        SpeakerSegment(speakerID: id, startSec: start, endSec: end)
    }

    /// Activity where the owner's mic dominates during [selfFrom, selfTo).
    private func activity(duration: Double, selfFrom: Double, selfTo: Double) -> MicActivity {
        let bins = (0..<Int(duration / MicActivity.binDuration)).map { i -> MicActivity.Bin in
            let t = Double(i) * MicActivity.binDuration
            return t >= selfFrom && t < selfTo
                ? MicActivity.Bin(mic: 0.5, sys: 0.01)
                : MicActivity.Bin(mic: 0.01, sys: 0.5)
        }
        return MicActivity(bins: bins)
    }

    func testSpeakersLabelledByFirstAppearanceAndMerged() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("как дела", 2, 4), seg("нормально", 5, 7)],
            speakers: [spk("A", 0, 4.5), spk("B", 4.5, 8)],
            activity: nil
        )
        XCTAssertEqual(text, "[Speaker 1] привет как дела\n[Speaker 2] нормально")
    }

    func testMicDominatedClusterBecomesSelf() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0, selfTo: 2.5)
        )
        XCTAssertEqual(text, "[Я] привет\n[Speaker 1] ответ")
    }

    func testSegmentWithoutOverlapInheritsPreviousSpeaker() {
        let text = RoleAssigner.render(
            segments: [seg("раз", 0, 2), seg("два", 10, 11)], // second overlaps nothing
            speakers: [spk("A", 0, 3)],
            activity: nil
        )
        XCTAssertEqual(text, "[Speaker 1] раз два")
    }

    func testEmptyInputsGiveNil() {
        XCTAssertNil(RoleAssigner.render(segments: [], speakers: [spk("A", 0, 1)], activity: nil))
        XCTAssertNil(RoleAssigner.render(segments: [seg("а", 0, 1)], speakers: [], activity: nil))
    }

    func testWeakMicDominanceDoesNotLabelSelf() {
        // Owner share below the 0.6 threshold → nobody is «Я».
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 4)],
            speakers: [spk("A", 0, 4)],
            activity: activity(duration: 4, selfFrom: 0, selfTo: 1) // 25% < 60%
        )
        XCTAssertEqual(text, "[Speaker 1] привет")
    }

    func testSingleSpeakerWholeCall() {
        let text = RoleAssigner.render(
            segments: [seg("монолог", 0, 10), seg("продолжение", 10, 20)],
            speakers: [spk("A", 0, 20)],
            activity: activity(duration: 20, selfFrom: 0, selfTo: 20)
        )
        XCTAssertEqual(text, "[Я] монолог продолжение")
    }

    // MARK: - Structured utterances (assign)

    func testAssignProducesMergedUtterancesWithTimeRanges() throws {
        let utterances = try XCTUnwrap(RoleAssigner.assign(
            segments: [seg("привет", 0, 2), seg("как дела", 2, 4), seg("нормально", 5, 7)],
            speakers: [spk("A", 0, 4.5), spk("B", 4.5, 8)],
            activity: nil
        ))
        XCTAssertEqual(utterances, [
            TranscriptUtterance(idx: 0, startSec: 0, endSec: 4, speaker: "Speaker 1", text: "привет как дела"),
            TranscriptUtterance(idx: 1, startSec: 5, endSec: 7, speaker: "Speaker 2", text: "нормально")
        ])
    }

    /// Pins the equivalence: the joined string is derived from `assign`'s
    /// structured utterances via the canonical renderer, and for identical
    /// input `render(segments→text)` equals the legacy line-joined output
    /// (asserted verbatim by the tests above).
    func testRenderEqualsCanonicalRenderOfAssign() throws {
        let scenarios: [(segments: [TranscriptSegment], speakers: [SpeakerSegment], activity: MicActivity?)] = [
            ([seg("привет", 0, 2), seg("как дела", 2, 4), seg("нормально", 5, 7)],
             [spk("A", 0, 4.5), spk("B", 4.5, 8)], nil),
            ([seg("привет", 0, 2), seg("ответ", 3, 5)],
             [spk("A", 0, 2.5), spk("B", 2.5, 5)], activity(duration: 5, selfFrom: 0, selfTo: 2.5)),
            ([seg("раз", 0, 2), seg("два", 10, 11)], [spk("A", 0, 3)], nil),
            ([seg("монолог", 0, 10), seg("продолжение", 10, 20)],
             [spk("A", 0, 20)], activity(duration: 20, selfFrom: 0, selfTo: 20))
        ]
        for (segments, speakers, activity) in scenarios {
            let utterances = try XCTUnwrap(RoleAssigner.assign(
                segments: segments, speakers: speakers, activity: activity))
            XCTAssertEqual(
                RoleAssigner.render(segments: segments, speakers: speakers, activity: activity),
                TranscriptSegments.render(utterances)
            )
        }
    }

    func testAssignEmptyInputsGiveNil() {
        XCTAssertNil(RoleAssigner.assign(segments: [], speakers: [spk("A", 0, 1)], activity: nil))
        XCTAssertNil(RoleAssigner.assign(segments: [seg("а", 0, 1)], speakers: [], activity: nil))
    }
}
