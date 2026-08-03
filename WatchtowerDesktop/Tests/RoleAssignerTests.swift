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

    /// A diarization under-split (one cluster covering many people) must not
    /// cement into one monolithic utterance: the merge breaks every 120 s,
    /// keeping the same speaker label.
    func testLongSameClusterRunSplitsAtDurationCap() throws {
        let texts = (0..<30).map { "фраза \($0)" }
        let segments = texts.enumerated().map { i, t in seg(t, Double(i) * 10, Double(i + 1) * 10) }
        let utterances = try XCTUnwrap(RoleAssigner.assign(
            segments: segments,
            speakers: [spk("A", 0, 300)],
            activity: nil
        ))
        XCTAssertGreaterThan(utterances.count, 1)
        for u in utterances {
            XCTAssertLessThanOrEqual(u.endSec - u.startSec, 120)
        }
        XCTAssertEqual(utterances.map(\.speaker), Array(repeating: "Speaker 1", count: utterances.count))
        XCTAssertEqual(utterances.map(\.idx), Array(0..<utterances.count))
        XCTAssertEqual(utterances.map(\.text).joined(separator: " "), texts.joined(separator: " "))
        XCTAssertEqual(utterances.first?.startSec, 0)
        XCTAssertEqual(utterances.last?.endSec, 300)
    }

    /// Boundary: a run spanning exactly the cap stays one utterance, so an
    /// ordinary meeting sees no behavior change.
    func testRunExactlyAtCapStaysOneUtterance() throws {
        let utterances = try XCTUnwrap(RoleAssigner.assign(
            segments: [seg("начало", 0, 60), seg("конец", 60, 120)],
            speakers: [spk("A", 0, 120)],
            activity: nil
        ))
        XCTAssertEqual(utterances, [
            TranscriptUtterance(idx: 0, startSec: 0, endSec: 120, speaker: "Speaker 1", text: "начало конец")
        ])
    }

    func testAssignEmptyInputsGiveNil() {
        XCTAssertNil(RoleAssigner.assign(segments: [], speakers: [spk("A", 0, 1)], activity: nil))
        XCTAssertNil(RoleAssigner.assign(segments: [seg("а", 0, 1)], speakers: [], activity: nil))
    }

    // MARK: - Voice-matched names (speaker identity)

    func testVoiceNameRendersInsteadOfSpeakerNumber() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: nil,
            voiceNames: ["B": "Саша"]
        )
        XCTAssertEqual(text, "[Speaker 1] привет\n[Саша] ответ")
    }

    /// «Я» (mic dominance) has absolute priority: a voice match can never
    /// claim the owner's cluster.
    func testSelfClusterKeepsLabelOverVoiceMatch() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0, selfTo: 2.5),
            voiceNames: ["A": "Alice", "B": "Bob"]
        )
        XCTAssertEqual(text, "[Я] привет\n[Bob] ответ")
    }

    /// Numbering stays dense over the remaining unnamed clusters.
    func testNumberingSkipsVoiceMatchedClusters() {
        let text = RoleAssigner.render(
            segments: [seg("раз", 0, 2), seg("два", 2.5, 4), seg("три", 5, 7)],
            speakers: [spk("A", 0, 2.4), spk("B", 2.4, 4.5), spk("C", 4.5, 8)],
            activity: nil,
            voiceNames: ["A": "Alice"]
        )
        XCTAssertEqual(text, "[Alice] раз\n[Speaker 1] два\n[Speaker 2] три")
    }

    /// Empty voiceNames (nil-embedding diarizers, empty voice-print DB) is
    /// byte-identical to the pre-identity behavior.
    func testEmptyVoiceNamesKeepsLegacyLabels() {
        let segments = [seg("привет", 0, 2), seg("ответ", 3, 5)]
        let speakers = [spk("A", 0, 2.5), spk("B", 2.5, 5)]
        XCTAssertEqual(
            RoleAssigner.render(segments: segments, speakers: speakers, activity: nil, voiceNames: [:]),
            RoleAssigner.render(segments: segments, speakers: speakers, activity: nil)
        )
    }

    func testClusterLabelsMatchAssignedUtteranceLabels() throws {
        let speakers = [spk("A", 0, 2.5), spk("B", 2.5, 5)]
        let labels = RoleAssigner.clusterLabels(speakers: speakers, activity: nil, voiceNames: ["B": "Саша"])
        XCTAssertEqual(labels, ["A": "Speaker 1", "B": "Саша"])
        let utterances = try XCTUnwrap(RoleAssigner.assign(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: speakers, activity: nil, voiceNames: ["B": "Саша"]))
        XCTAssertEqual(utterances.map(\.speaker), ["Speaker 1", "Саша"])
    }
}
