import XCTest
@testable import WatchtowerDesktop

final class VoicePrintMatcherTests: XCTestCase {

    private func makePrint(_ personKey: String, _ name: String, _ vector: [Float], sampleCount: Int = 1) -> VoicePrint {
        VoicePrint(id: nil, personKey: personKey, displayName: name,
                   embedding: VoicePrintEmbedding.encode(vector),
                   sampleCount: sampleCount, updatedAt: "")
    }

    // MARK: - Embedding BLOB codec

    func testEmbeddingBlobRoundTrip() {
        let vector: [Float] = [0.25, -1.5, 3.0]
        XCTAssertEqual(VoicePrintEmbedding.decode(VoicePrintEmbedding.encode(vector)), vector)
    }

    func testEmbeddingDecodeRejectsOddLengthBlob() {
        XCTAssertEqual(VoicePrintEmbedding.decode(Data([0x01, 0x02, 0x03])), [])
        XCTAssertEqual(VoicePrintEmbedding.decode(Data()), [])
    }

    // MARK: - Cosine matching

    func testMatchAboveThresholdWins() {
        let prints = [makePrint("a@x.com", "Alice", [1, 0])]
        let match = VoicePrintMatcher.bestMatch(embedding: [0.9, 0.1], prints: prints)
        XCTAssertEqual(match?.displayName, "Alice")
    }

    func testMatchBelowThresholdIsNil() {
        // Orthogonal vectors: cosine 0 < 0.7.
        let prints = [makePrint("a@x.com", "Alice", [1, 0])]
        XCTAssertNil(VoicePrintMatcher.bestMatch(embedding: [0, 1], prints: prints))
    }

    func testExactThresholdMatches() {
        // cos = 0.7 exactly (unit vectors at the threshold angle).
        let angle = acos(VoicePrintMatcher.matchThreshold)
        let prints = [makePrint("a@x.com", "Alice", [1, 0])]
        let match = VoicePrintMatcher.bestMatch(embedding: [cos(angle), sin(angle)], prints: prints)
        XCTAssertEqual(match?.displayName, "Alice", "cosine == threshold must count as a match")
    }

    func testEmptyDatabaseGivesNoMatch() {
        XCTAssertNil(VoicePrintMatcher.bestMatch(embedding: [1, 0], prints: []))
    }

    func testMultipleCandidatesBestWins() {
        let prints = [
            makePrint("a@x.com", "Alice", [1, 0]),
            makePrint("b@x.com", "Bob", [0.8, 0.6])
        ]
        // Closer to Bob's direction than Alice's.
        let match = VoicePrintMatcher.bestMatch(embedding: [0.78, 0.62], prints: prints)
        XCTAssertEqual(match?.displayName, "Bob")
    }

    func testZeroVectorEmbeddingRejected() {
        let prints = [makePrint("a@x.com", "Alice", [1, 0])]
        XCTAssertNil(VoicePrintMatcher.bestMatch(embedding: [0, 0], prints: prints))
        XCTAssertNil(VoicePrintMatcher.bestMatch(embedding: [], prints: prints))
    }

    func testZeroVectorPrintSkipped() {
        // A corrupt (zero) centroid must never match; a later valid print still can.
        let prints = [
            makePrint("z@x.com", "Zero", [0, 0]),
            makePrint("a@x.com", "Alice", [1, 0])
        ]
        let match = VoicePrintMatcher.bestMatch(embedding: [1, 0], prints: prints)
        XCTAssertEqual(match?.displayName, "Alice")
    }

    func testDimensionMismatchPrintSkipped() {
        let prints = [makePrint("a@x.com", "Alice", [1, 0, 0])]
        XCTAssertNil(VoicePrintMatcher.bestMatch(embedding: [1, 0], prints: prints))
    }

    // MARK: - Normalize

    func testNormalizeProducesUnitVector() throws {
        let normalized = try XCTUnwrap(VoicePrintMatcher.normalize([3, 4]))
        XCTAssertEqual(normalized[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 1e-6)
    }

    func testNormalizeRejectsZeroAndEmpty() {
        XCTAssertNil(VoicePrintMatcher.normalize([0, 0, 0]))
        XCTAssertNil(VoicePrintMatcher.normalize([]))
    }

    // MARK: - Centroid update

    func testUpdatedCentroidStaysNormalized() throws {
        let centroid: [Float] = [1, 0]
        let updated = try XCTUnwrap(VoicePrintMatcher.updatedCentroid(
            centroid: centroid, sampleCount: 3, embedding: [0, 1]))
        let norm = sqrt(updated.reduce(Float(0)) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-5, "centroid must stay L2-normalized")
        // centroid·3 + emb = [3, 1] → direction preserved.
        XCTAssertEqual(updated[0] / updated[1], 3.0, accuracy: 1e-4)
    }

    func testUpdatedCentroidRejectsDimensionMismatch() {
        XCTAssertNil(VoicePrintMatcher.updatedCentroid(centroid: [1, 0], sampleCount: 1, embedding: [1, 0, 0]))
    }

    func testUpdatedCentroidRejectsCancellation() {
        // centroid·1 + (-centroid) = zero vector → nil, print left unchanged.
        XCTAssertNil(VoicePrintMatcher.updatedCentroid(centroid: [1, 0], sampleCount: 1, embedding: [-1, 0]))
    }

    func testUpdatedCentroidRejectsNonPositiveSampleCount() {
        XCTAssertNil(VoicePrintMatcher.updatedCentroid(centroid: [1, 0], sampleCount: 0, embedding: [0, 1]))
    }

    // MARK: - Attendee scoping

    private func makeAttendee(email: String, name: String) -> EventAttendee {
        EventAttendee(email: email, displayName: name, responseStatus: "accepted", slackUserID: "")
    }

    func testScopedKeepsOnlyAttendeePrints() {
        let prints = [
            makePrint("alice@x.com", "alice@x.com", [1, 0]),
            makePrint("stranger@y.com", "stranger@y.com", [0, 1])
        ]
        let attendees = [makeAttendee(email: "Alice@X.com", name: "Alice")]
        let scoped = VoicePrintMatcher.scoped(prints, attendees: attendees, ownerEmails: [])
        XCTAssertEqual(scoped.map(\.personKey), ["alice@x.com"],
                       "a print for someone not on the event must be dropped")
    }

    func testScopedMatchesByDisplayName() {
        // A print learned from a free-text rename has no email — its personKey
        // is the normalized name; the attendee side may only know the display name.
        let prints = [makePrint("саша петров", "Саша Петров", [1, 0])]
        let attendees = [makeAttendee(email: "sasha@corp.com", name: "саша петров")]
        XCTAssertEqual(VoicePrintMatcher.scoped(prints, attendees: attendees, ownerEmails: []).count, 1)
    }

    func testScopedEmptyAttendeesKeepsAll() {
        // Ad-hoc recording (no event, no attendee list) — matching stays global.
        let prints = [
            makePrint("alice@x.com", "Alice", [1, 0]),
            makePrint("bob@y.com", "Bob", [0, 1])
        ]
        XCTAssertEqual(VoicePrintMatcher.scoped(prints, attendees: [], ownerEmails: []).count, 2)
    }

    func testScopedDisplayNameBranchAloneKeepsPrint() {
        // The print's displayName (not its personKey) matches the attendee —
        // isolates the displayName alternative of the filter.
        let prints = [makePrint("куратор", "Пётр Кузнецов", [1, 0])]
        let attendees = [makeAttendee(email: "petr@corp.com", name: " пётр кузнецов ")]
        XCTAssertEqual(VoicePrintMatcher.scoped(prints, attendees: attendees, ownerEmails: []).count, 1)
    }

    func testScopedEmptyAttendeeFieldsNeverMatch() {
        // A room resource row can carry an empty email — it must not admit
        // arbitrary prints via ""-to-"" comparisons.
        let prints = [makePrint("stranger@y.com", "stranger@y.com", [1, 0])]
        let attendees = [makeAttendee(email: "", name: "Meeting Room 6")]
        XCTAssertTrue(VoicePrintMatcher.scoped(prints, attendees: attendees, ownerEmails: []).isEmpty)
    }

    func testScopedAlwaysKeepsOwnerPrints() {
        // The owner is present at their own recording by definition (it is
        // their mic), even when the attendee list does not carry their email
        // (organizer-only entry, group alias, CalDAV/ICS event).
        let prints = [
            makePrint("owner@x.com", "owner@x.com", [1, 0]),
            makePrint("stranger@y.com", "stranger@y.com", [0, 1])
        ]
        let attendees = [makeAttendee(email: "alice@z.com", name: "Alice")]
        let scoped = VoicePrintMatcher.scoped(prints, attendees: attendees, ownerEmails: ["owner@x.com"])
        XCTAssertEqual(scoped.map(\.personKey), ["owner@x.com"],
                       "the owner's print must survive scoping; the stranger's must not")
    }

    func testScopedNormalizesPersonKeyLikeDisplayName() {
        // Trim + case-fold must be symmetric on both sides of the compare —
        // the print writer (SpeakerNaming.personKey) already trims+lowercases,
        // and the reader must not silently depend on that.
        let prints = [makePrint(" Alice@X.com ", "Alice", [1, 0])]
        let attendees = [makeAttendee(email: "alice@x.com", name: "")]
        XCTAssertEqual(VoicePrintMatcher.scoped(prints, attendees: attendees, ownerEmails: []).count, 1)
    }

    func testIsOwnerPrintMatchesNormalizedEmailKey() {
        XCTAssertTrue(VoicePrintMatcher.isOwnerPrint(
            makePrint(" Owner@X.com ", "Owner", [1, 0]), ownerEmails: ["owner@x.com"]))
        // Normalization is symmetric — a loader that forgets to lowercase
        // must not silently kill owner detection.
        XCTAssertTrue(VoicePrintMatcher.isOwnerPrint(
            makePrint("owner@x.com", "Owner", [1, 0]), ownerEmails: ["Owner@X.com "]))
        // A name-keyed print (ad-hoc/free-text rename mint path) is NOT
        // recognizable as the owner's — callers must then disarm the owner
        // logic rather than treat the owner as a stranger.
        XCTAssertFalse(VoicePrintMatcher.isOwnerPrint(
            makePrint("vadym", "vadym", [1, 0]), ownerEmails: ["owner@x.com"]))
        XCTAssertFalse(VoicePrintMatcher.isOwnerPrint(
            makePrint("owner@x.com", "Owner", [1, 0]), ownerEmails: []))
    }

    // MARK: - SpeakerNaming

    func testIsUnnamedMatchesDefaultLabelsOnly() {
        XCTAssertTrue(SpeakerNaming.isUnnamed("Speaker 1"))
        XCTAssertTrue(SpeakerNaming.isUnnamed("Speaker 12"))
        XCTAssertFalse(SpeakerNaming.isUnnamed("Я"))
        XCTAssertFalse(SpeakerNaming.isUnnamed("Alice"))
        XCTAssertFalse(SpeakerNaming.isUnnamed("Speaker"))
        XCTAssertFalse(SpeakerNaming.isUnnamed("Speaker one"))
    }

    func testPersonKeyPrefersAttendeeEmail() {
        let attendees = [
            EventAttendee(email: "sasha@corp.com", displayName: "Саша Петров",
                          responseStatus: "accepted", slackUserID: "")
        ]
        XCTAssertEqual(SpeakerNaming.personKey(for: "Саша Петров", attendees: attendees), "sasha@corp.com")
        XCTAssertEqual(SpeakerNaming.personKey(for: "sasha@corp.com", attendees: attendees), "sasha@corp.com")
    }

    func testPersonKeyFallsBackToNormalizedName() {
        XCTAssertEqual(SpeakerNaming.personKey(for: "  Random Person ", attendees: []), "random person")
    }
}
