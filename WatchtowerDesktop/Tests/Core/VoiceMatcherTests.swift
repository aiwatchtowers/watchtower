import XCTest
@testable import WatchtowerCore

final class VoiceMatcherTests: XCTestCase {
    private func unit(_ angle: Float) -> [Float] {
        var v = [Float](repeating: 0, count: 4)
        v[0] = cos(angle)
        v[1] = sin(angle)
        return v
    }

    private func sample(
        _ id: Int64,
        person: Int64,
        _ v: [Float],
        status: VoiceSampleStatus = .active,
        origin: VoiceSampleOrigin = .owner,
        model: String = VoiceRegistryPolicy.embeddingModelVersion
    ) -> VoiceSample {
        VoiceSample(id: id, personID: person, embedding: VoicePrintEmbedding.encode(v), modelVersion: model,
                    origin: origin, anchor: origin == .owner, status: status)
    }

    private func cluster(_ label: String, _ v: [Float], speech: Double = 60) -> VoiceMatcher.Cluster {
        .init(label: label, embedding: v, speechSec: speech)
    }

    func testNearestSampleWinsOverAveragedCentroid() {
        // person 1 has two channel variants 90° apart; the cluster matches one exactly
        let s = [sample(1, person: 1, unit(0)), sample(2, person: 1, unit(.pi / 2)), sample(3, person: 2, unit(.pi))]
        let d = VoiceMatcher.decide(clusters: [cluster("Speaker 1", unit(.pi / 2))], samples: s,
                                    invited: [1, 2], ownerPersonIDs: [])
        XCTAssertEqual(d["Speaker 1"], .confident(personID: 1, sampleID: 2, score: 1))
    }

    /// Spec §5: an imported sample ≥ 0.80 to a DIFFERENT person than the
    /// confident local winner raises a conflict instead of a silent label.
    func testPendingImportOfAnotherPersonTurnsConfidentIntoConflict() {
        let local = sample(1, person: 1, unit(0))
        let d = VoiceMatcher.decide(
            clusters: [cluster("Speaker 1", unit(0))],
            samples: [local, sample(2, person: 2, unit(0.3), status: .pending, origin: .imported)],
            invited: [1, 2], ownerPersonIDs: [])
        XCTAssertEqual(d["Speaker 1"], .unsure(personID: 1, score: 1, reason: .conflict))

        // The same person's pending sample agrees; a far one (cos 0.54) says nothing.
        for pending in [sample(2, person: 1, unit(0.3), status: .pending, origin: .imported),
                        sample(2, person: 2, unit(1.0), status: .pending, origin: .imported)] {
            let agreed = VoiceMatcher.decide(clusters: [cluster("Speaker 1", unit(0))], samples: [local, pending],
                                             invited: [1, 2], ownerPersonIDs: [])
            XCTAssertEqual(agreed["Speaker 1"], .confident(personID: 1, sampleID: 1, score: 1))
        }
    }

    /// Spec §2.2 "sources disagree": two senders' pending samples name the
    /// same voice as two different people.
    func testTwoImportsClaimingOneVoiceForDifferentPeopleIsConflict() {
        let a = sample(1, person: 2, unit(0), status: .pending, origin: .imported)
        let b = sample(2, person: 3, unit(0.3), status: .pending, origin: .imported)
        let d = VoiceMatcher.decide(clusters: [cluster("Speaker 1", unit(0))], samples: [a, b],
                                    invited: [2, 3], ownerPersonIDs: [])
        XCTAssertEqual(d["Speaker 1"], .unsure(personID: 2, score: 1, reason: .conflict))

        let sameSender = sample(2, person: 2, unit(0.3), status: .pending, origin: .imported)
        let agreed = VoiceMatcher.decide(clusters: [cluster("Speaker 1", unit(0))], samples: [a, sameSender],
                                         invited: [2, 3], ownerPersonIDs: [])
        XCTAssertEqual(agreed["Speaker 1"], .unsure(personID: 2, score: 1, reason: .importConfirm))
    }

    func testMarginBelowPointOneIsConflict() {
        let s = [sample(1, person: 1, unit(0)), sample(2, person: 2, unit(0.05))]
        let d = VoiceMatcher.decide(clusters: [cluster("Speaker 1", unit(0.02))], samples: s,
                                    invited: [1, 2], ownerPersonIDs: [])
        guard case .unsure(_, _, .conflict) = d["Speaker 1"] else {
            return XCTFail("\(String(describing: d["Speaker 1"]))")
        }
    }

    func testNotInvitedStrongMatchIsUnsure() {
        let s = [sample(1, person: 1, unit(0))]
        let d = VoiceMatcher.decide(clusters: [cluster("Speaker 1", unit(0))], samples: s,
                                    invited: [9], ownerPersonIDs: [])
        XCTAssertEqual(d["Speaker 1"], .unsure(personID: 1, score: 1, reason: .unsure))
    }

    func testOwnerIsAlwaysInvited() {
        let s = [sample(1, person: 1, unit(0))]
        let d = VoiceMatcher.decide(clusters: [cluster("Speaker 1", unit(0))], samples: s,
                                    invited: [9], ownerPersonIDs: [1])
        XCTAssertEqual(d["Speaker 1"], .confident(personID: 1, sampleID: 1, score: 1))
    }

    func testNoEventNeedsPointSevenFive() {
        let s = [sample(1, person: 1, unit(0))]
        let c = cluster("Speaker 1", unit(acos(0.72)))   // cosine 0.72
        XCTAssertEqual(VoiceMatcher.decide(clusters: [c], samples: s, invited: nil, ownerPersonIDs: [])["Speaker 1"],
                       .unsure(personID: 1, score: 0.72, reason: .unsure))
    }

    func testUnsureBandAndUnknown() {
        let s = [sample(1, person: 1, unit(0))]
        let unsure = VoiceMatcher.decide(clusters: [cluster("A", unit(acos(0.6)))], samples: s,
                                         invited: [1], ownerPersonIDs: [])
        XCTAssertEqual(unsure["A"], .unsure(personID: 1, score: 0.6, reason: .unsure))
        let unknown = VoiceMatcher.decide(clusters: [cluster("B", unit(acos(0.3)))], samples: s,
                                          invited: [1], ownerPersonIDs: [])
        XCTAssertEqual(unknown["B"], .unknown(bestScore: 0.3))
    }

    func testShortClusterNeverMatches() {
        let s = [sample(1, person: 1, unit(0))]
        XCTAssertEqual(VoiceMatcher.decide(clusters: [cluster("A", unit(0), speech: 19)], samples: s,
                                           invited: [1], ownerPersonIDs: [])["A"], .tooShort)
    }

    func testPendingImportedOnlyYieldsImportConfirm() {
        let s = [sample(1, person: 1, unit(0), status: .pending, origin: .imported)]
        XCTAssertEqual(VoiceMatcher.decide(clusters: [cluster("A", unit(0))], samples: s,
                                           invited: [1], ownerPersonIDs: [])["A"],
                       .unsure(personID: 1, score: 1, reason: .importConfirm))
    }

    func testRetiredAndOtherModelAndCorruptSamplesAreIgnored() {
        var corrupt = sample(3, person: 3, unit(0))
        corrupt.embedding = Data([1, 2, 3])
        let s = [sample(1, person: 1, unit(0), status: .retired), sample(2, person: 2, unit(0), model: "other"), corrupt,
                 sample(4, person: 4, [1, 0])]                        // dimension mismatch
        XCTAssertEqual(VoiceMatcher.decide(clusters: [cluster("A", unit(0))], samples: s,
                                           invited: [1, 2, 3, 4], ownerPersonIDs: [])["A"],
                       .unknown(bestScore: 0))
    }

    func testOnePersonAtMostOneConfidentClusterPerRecording() {
        let s = [sample(1, person: 1, unit(0))]
        let d = VoiceMatcher.decide(clusters: [cluster("A", unit(0)), cluster("B", unit(acos(0.9)))], samples: s,
                                    invited: [1], ownerPersonIDs: [])
        XCTAssertEqual(d["A"], .confident(personID: 1, sampleID: 1, score: 1))
        XCTAssertEqual(d["B"], .unsure(personID: 1, score: 0.9, reason: .unsure))
    }

    /// The stronger cluster keeps the person regardless of input order: a
    /// later, better cluster demotes the earlier confident one.
    func testOnePersonRuleIsIndependentOfClusterOrder() {
        let s = [sample(1, person: 1, unit(0))]
        let d = VoiceMatcher.decide(clusters: [cluster("B", unit(0)), cluster("A", unit(acos(0.9)))], samples: s,
                                    invited: [1], ownerPersonIDs: [])
        XCTAssertEqual(d["B"], .confident(personID: 1, sampleID: 1, score: 1))
        XCTAssertEqual(d["A"], .unsure(personID: 1, score: 0.9, reason: .unsure))
    }

    /// Ported from the retired VoicePrintMatcher suite: a degenerate vector
    /// (zero, empty) or a dimension mismatch never produces a score.
    func testDegenerateVectorsNeverMatch() throws {
        XCTAssertNil(VoiceMatcher.normalize([0, 0, 0]))
        XCTAssertNil(VoiceMatcher.normalize([]))
        XCTAssertNil(VoiceMatcher.normalize([.infinity, 1]))
        let normalized = try XCTUnwrap(VoiceMatcher.normalize([3, 4]))
        XCTAssertEqual(normalized[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 1e-6)
        XCTAssertNil(VoiceMatcher.cosine([0, 0], [1, 0]))
        XCTAssertNil(VoiceMatcher.cosine([1, 0], [1, 0, 0]))
        XCTAssertNil(VoiceMatcher.cosine([], []))
        XCTAssertEqual(try XCTUnwrap(VoiceMatcher.cosine([2, 0], [1, 0])), 1, accuracy: 1e-6)

        let zero = sample(1, person: 1, [0, 0, 0, 0])
        XCTAssertTrue(VoiceMatcher.nearest(embedding: unit(0), samples: [zero]).isEmpty)
        XCTAssertTrue(VoiceMatcher.nearest(embedding: [0, 0, 0, 0], samples: [sample(2, person: 2, unit(0))]).isEmpty)
    }

    func testNearestKeepsOneEntryPerPersonSortedDescending() {
        let s = [sample(1, person: 1, unit(0.5)), sample(2, person: 1, unit(0)), sample(3, person: 2, unit(1))]
        let ranked = VoiceMatcher.nearest(embedding: unit(0), samples: s)
        XCTAssertEqual(ranked.map(\.personID), [1, 2])
        XCTAssertEqual(ranked.first?.sampleID, 2)
    }

    // MARK: - Ported: embedding BLOB codec + SpeakerNaming

    func testEmbeddingBlobRoundTrip() {
        let vector: [Float] = [0.25, -1.5, 3.0]
        XCTAssertEqual(VoicePrintEmbedding.decode(VoicePrintEmbedding.encode(vector)), vector)
        XCTAssertEqual(VoicePrintEmbedding.decode(Data([0x01, 0x02, 0x03])), [])
        XCTAssertEqual(VoicePrintEmbedding.decode(Data()), [])
    }

    func testIsUnnamedMatchesDefaultLabelsOnly() {
        XCTAssertTrue(SpeakerNaming.isUnnamed("Speaker 1"))
        XCTAssertTrue(SpeakerNaming.isUnnamed("Speaker 12"))
        XCTAssertFalse(SpeakerNaming.isUnnamed("Я"))
        XCTAssertFalse(SpeakerNaming.isUnnamed("Alice"))
        XCTAssertFalse(SpeakerNaming.isUnnamed("Speaker"))
        XCTAssertFalse(SpeakerNaming.isUnnamed("Speaker one"))
    }

    func testPersonKeyPrefersAttendeeEmailElseNormalizedName() {
        let attendees = [EventAttendee(email: "sasha@example.com", displayName: "Саша Петров",
                                       responseStatus: "accepted", slackUserID: "")]
        XCTAssertEqual(SpeakerNaming.personKey(for: "Саша Петров", attendees: attendees), "sasha@example.com")
        XCTAssertEqual(SpeakerNaming.personKey(for: "sasha@example.com", attendees: attendees), "sasha@example.com")
        XCTAssertEqual(SpeakerNaming.personKey(for: "  Random Person ", attendees: []), "random person")
    }

    /// Another person's samples at ≥ `importConflict` are what an owner's
    /// confirm contradicts — pending imports and active samples (anchors
    /// included) alike; the confirmed person's own, a far sample, a retired
    /// one or another model's are not.
    func testContradictingSamplesAreAnotherPersonsSamplesOnThisVoice() {
        let samples = [
            sample(1, person: 2, unit(0.3), status: .pending, origin: .imported), // cos 0.955 — contradicting
            sample(2, person: 2, unit(1.0), status: .pending, origin: .imported), // cos 0.54 — far
            sample(3, person: 1, unit(0.1), status: .pending, origin: .imported), // the confirmed person
            sample(4, person: 3, unit(0.1)), // another person's active anchor — contradicting
            sample(5, person: 3, unit(0.1), status: .pending, origin: .imported, model: "older-model"),
            sample(6, person: 3, unit(0.1), status: .retired)
        ]
        let out = VoiceMatcher.contradictingSamples(embedding: unit(0), samples: samples, confirmedPersonID: 1)
        XCTAssertEqual(out.compactMap(\.id), [1, 4])
    }

    /// The owner's own people are exempt: a colleague confirmed on a voice
    /// close to the owner's never contradicts the owner's samples.
    func testContradictingSamplesNeverIncludeExemptOwnerPeople() {
        let samples = [sample(1, person: 9, unit(0.1)), sample(2, person: 3, unit(0.1))]
        let out = VoiceMatcher.contradictingSamples(embedding: unit(0), samples: samples, confirmedPersonID: 1,
                                                    exemptPersonIDs: [9])
        XCTAssertEqual(out.compactMap(\.id), [2])
    }

    /// A conflict confirmed as the imported person activates only an import
    /// of theirs that actually claimed the voice (≥ `confident`).
    func testClaimingPendingNeedsTheConfirmedPersonsOwnConfidentImport() {
        let near = sample(1, person: 2, unit(0.3), status: .pending, origin: .imported)
        let far = sample(2, person: 2, unit(1.2), status: .pending, origin: .imported)
        let other = sample(3, person: 3, unit(0), status: .pending, origin: .imported)
        XCTAssertEqual(VoiceMatcher.claimingPending(embedding: unit(0), samples: [far, near, other], personID: 2)?.id, 1)
        XCTAssertNil(VoiceMatcher.claimingPending(embedding: unit(0), samples: [far, other], personID: 2))
    }

    /// A person the owner rejected for a cluster is never assigned to it (nor
    /// suggested at the confident bar), and the rejected cluster does not
    /// take that person's one-per-recording slot from another cluster.
    func testRejectedPersonIsNeverConfidentForThatCluster() {
        let s = [sample(1, person: 1, unit(0))]
        let d = VoiceMatcher.decide(
            clusters: [.init(label: "Speaker 1", embedding: unit(0), speechSec: 60, rejectedPersonIDs: [1]),
                       cluster("Speaker 2", unit(0.2))],
            samples: s, invited: [1], ownerPersonIDs: [])
        XCTAssertEqual(d["Speaker 1"], .unsure(personID: nil, score: 1, reason: .unsure))
        XCTAssertEqual(d["Speaker 2"], .confident(personID: 1, sampleID: 1, score: cos(0.2)))
    }
}
