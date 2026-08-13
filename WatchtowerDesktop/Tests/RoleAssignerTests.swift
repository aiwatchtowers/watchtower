import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

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

    /// The cap splits BETWEEN segments, never inside one: a single segment
    /// longer than 120 s has no cut point the transcriber offered, so it stays
    /// one utterance (the `!currentTexts.isEmpty` guard in `assign`). Splitting
    /// it would invent timings the engine never reported.
    func testSingleSegmentLongerThanTheCapIsNotSplit() throws {
        let utterances = try XCTUnwrap(RoleAssigner.assign(
            segments: [seg("один очень длинный монолог", 0, 400)],
            speakers: [spk("A", 0, 400)],
            activity: nil
        ))
        XCTAssertEqual(utterances, [
            TranscriptUtterance(idx: 0, startSec: 0, endSec: 400,
                                speaker: "Speaker 1", text: "один очень длинный монолог")
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

    /// Without owner identity (`ownerClusters` nil — no Google account, load
    /// failure), «Я» (mic dominance) keeps absolute priority: a voice match
    /// can never claim the owner's cluster. This is the legacy default.
    func testSelfClusterKeepsLabelOverVoiceMatchWithoutOwnerIdentity() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0, selfTo: 2.5),
            voiceNames: ["A": "Alice", "B": "Bob"]
        )
        XCTAssertEqual(text, "[Я] привет\n[Bob] ответ")
    }

    // MARK: - Owner voice identity vs mic dominance (group-meeting fixes)

    /// A mic-dominant cluster that confidently matches the OWNER's voice
    /// print keeps «Я» even though it also carries a voice name.
    func testOwnerMatchedSelfClusterKeepsLabel() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0, selfTo: 2.5),
            voiceNames: ["A": "vadym@x.com", "B": "Bob"],
            ownerClusters: ["A"]
        )
        XCTAssertEqual(text, "[Я] привет\n[Bob] ответ")
    }

    /// Veto: when owner identity IS known and the mic-dominant winner
    /// confidently matches a colleague (not the owner), the «Я» label is
    /// withheld — every colleague's words must not render as the owner's.
    func testStrangerVoiceMatchVetoesSelfLabel() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0, selfTo: 2.5),
            voiceNames: ["A": "Alice", "B": "Bob"],
            ownerClusters: []
        )
        XCTAssertEqual(text, "[Alice] привет\n[Bob] ответ")
    }

    /// The veto needs a positive stranger match — a mic-dominant cluster with
    /// no voice name at all stays «Я» (an unnamed owner must not lose the
    /// label just because their print is missing).
    func testUnmatchedMicDominantClusterStaysSelf() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0, selfTo: 2.5),
            voiceNames: ["B": "Bob"],
            ownerClusters: []
        )
        XCTAssertEqual(text, "[Я] привет\n[Bob] ответ")
    }

    /// Meeting-room tie-break: several clusters clear the mic-dominance
    /// threshold (everyone speaks through the owner's mic); the one matching
    /// the owner's voice print wins «Я» over the louder one.
    func testOwnerVoiceMatchWinsSelfTieBreak() {
        // A: mic-dominant on [0.5, 2.5) of its 2.5 s → share 0.8.
        // B: mic-dominant on all of [2.5, 5) → share 1.0 (the louder one).
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0.5, selfTo: 5),
            voiceNames: ["A": "vadym@x.com"],
            ownerClusters: ["A"]
        )
        XCTAssertEqual(text, "[Я] привет\n[Speaker 1] ответ")
    }

    /// Same tie shape without an owner match: the max-share cluster wins «Я»
    /// exactly as before — the tie-break never activates on share alone.
    func testTieBreakWithoutOwnerMatchKeepsMaxShareWinner() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0.5, selfTo: 5),
            voiceNames: [:],
            ownerClusters: []
        )
        XCTAssertEqual(text, "[Speaker 1] привет\n[Я] ответ")
    }

    /// The legacy (nil ownerClusters) path over the SAME multi-candidate
    /// shape: max share wins, byte-identical to pre-refactor behavior — pins
    /// the threshold-then-argmax rewrite of detectSelfCluster.
    func testLegacyNilPathKeepsMaxShareWinnerAcrossMultipleCandidates() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0.5, selfTo: 5)
        )
        XCTAssertEqual(text, "[Speaker 1] привет\n[Я] ответ")
    }

    /// Owner split across clusters by the diarizer: with several
    /// owner-matched mic-dominant candidates the max-share one wins «Я».
    func testMultipleOwnerCandidatesMaxShareWins() {
        let labels = RoleAssigner.clusterLabels(
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0.5, selfTo: 5), // A: 0.8, B: 1.0
            voiceNames: ["A": "vadym@x.com", "B": "vadym@x.com"],
            ownerClusters: ["A", "B"]
        )
        XCTAssertEqual(labels["B"], "Я")
        XCTAssertEqual(labels["A"], "vadym@x.com")
    }

    /// The conservative owner rule: an `ownerVoiceAlike` cluster (an owner
    /// print also matches it ≥ threshold, even though its winning match is a
    /// colleague) is protected from the veto — but never PROMOTED to «Я»
    /// beyond what mic dominance already gives it.
    func testOwnerVoiceAlikeWinnerIsNotVetoed() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0, selfTo: 2.5),
            voiceNames: ["A": "Alice", "B": "Bob"],
            ownerClusters: [],
            ownerVoiceAlike: ["A"]
        )
        XCTAssertEqual(text, "[Я] привет\n[Bob] ответ",
                       "a cluster the owner's print also matches must keep «Я», not be vetoed")
    }

    /// The veto needs at least two distinct clusters: a single-cluster
    /// recording is an under-split 1:1, where a confident colleague match on
    /// the whole blob must not strip «Я» (the mega-cluster guard is off
    /// below 4 clusters by design, so this gate is the only protection).
    func testSingleClusterIsNeverVetoed() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 5)],
            activity: activity(duration: 5, selfFrom: 0, selfTo: 5),
            voiceNames: ["A": "Alice"],
            ownerClusters: []
        )
        XCTAssertEqual(text, "[Я] привет ответ")
    }

    /// An empty-string voice name is "no match", never a veto reason.
    func testEmptyVoiceNameDoesNotVeto() {
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0, selfTo: 2.5),
            voiceNames: ["A": "", "B": "Bob"],
            ownerClusters: []
        )
        XCTAssertEqual(text, "[Я] привет\n[Bob] ответ")
    }

    /// Pinned design decision (owner-reviewed): an owner voice match BELOW
    /// the mic-dominance threshold is not a «Я» candidate — the veto on a
    /// colleague-matched winner then leaves the transcript with no «Я» at
    /// all, which the owner ranked better than a wrong «Я».
    func testOwnerBelowThresholdDoesNotRescueVetoedWinner() {
        // A mic-dominant on [0, 2.5) only → cluster B (owner-matched) has
        // share 0 (below threshold); A is the sole candidate and matches
        // Alice → veto → nobody is «Я».
        let text = RoleAssigner.render(
            segments: [seg("привет", 0, 2), seg("ответ", 3, 5)],
            speakers: [spk("A", 0, 2.5), spk("B", 2.5, 5)],
            activity: activity(duration: 5, selfFrom: 0, selfTo: 2.5),
            voiceNames: ["A": "Alice", "B": "vadym@x.com"],
            ownerClusters: ["B"]
        )
        XCTAssertEqual(text, "[Alice] привет\n[vadym@x.com] ответ")
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
