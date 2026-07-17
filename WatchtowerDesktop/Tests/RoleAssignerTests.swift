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
}
