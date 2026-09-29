import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Voices window's Train screen (spec §4.2): `VoiceRegistryCenter.loadTrain`
/// building cross-meeting groups (audio-less exclusion, live regrouping) and
/// its `confirmGroup`/`dismissGroup` transactions. `VoiceGrouping` itself is
/// covered by `VoiceGroupingTests` (Tests/Core) — this file is the
/// DB-integration layer on top of it.
@MainActor
final class VoiceTrainTests: XCTestCase {
    nonisolated private func oneUtterance(_ speaker: String) -> [TranscriptUtterance] {
        [TranscriptUtterance(idx: 0, startSec: 1, endSec: 6, speaker: speaker, text: "hi there")]
    }

    /// Inserts a one-cluster segmented transcript whose cluster is a Train
    /// candidate: unnamed ("Speaker 1"), `label_source: none`, an embedding
    /// close to `[1, 0]` (so same-vector fixtures across transcripts merge)
    /// and, when `audioPath` is given, a clip so it can play back.
    @discardableResult
    nonisolated private func insertTranscript(
        _ db: Database, title: String = "Rec", audioPath: String?, embedding: String = "[1,0]", eventID: String? = nil
    ) throws -> Int64 {
        let speakersJSON = #"[{"speaker":"Speaker 1","embedding":\#(embedding),"clips":[{"start":1,"end":6}]}]"#
        try TestDatabase.insertMeetingTranscript(
            db, eventID: eventID, title: title, audioPath: audioPath,
            transcriptText: TranscriptSegments.render(self.oneUtterance("Speaker 1")),
            segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(self.oneUtterance("Speaker 1"))),
            speakersJSON: speakersJSON)
        return db.lastInsertedRowID
    }

    nonisolated private func cluster(_ db: Database, transcriptID: Int64) throws -> SpeakerEmbedding? {
        try MeetingTranscriptQueries.fetch(db, id: transcriptID)?.speakerEmbeddings?.first
    }

    // MARK: - loadTrain grouping

    /// A group with at least one audio member keeps EVERY member, including
    /// audio-less ones — they just never get their own clip row (`VoiceTrainView`'s
    /// job, not the center's).
    func testGroupKeepsAudiolessMembersWhenAtLeastOneMemberHasAudio() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let (withAudio, withoutAudio) = try await pool.write { db -> (Int64, Int64) in
            let withAudio = try self.insertTranscript(db, title: "Has audio", audioPath: audio.path)
            let withoutAudio = try self.insertTranscript(db, title: "No audio", audioPath: "/nonexistent.caf")
            return (withAudio, withoutAudio)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadTrain()

        XCTAssertNil(center.lastError)
        let group = try XCTUnwrap(center.groups.first)
        XCTAssertEqual(center.groups.count, 1)
        XCTAssertEqual(Set(group.members.map(\.transcriptID)), [withAudio, withoutAudio])
        XCTAssertEqual(group.audioMembers.map(\.transcriptID), [withAudio], "only the audio member is playable")
    }

    /// A group whose every member's recording lost its audio is dropped
    /// entirely — Train never shows a card with nothing to listen to.
    func testGroupWithNoAudioMemberIsDropped() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }

        try await pool.write { db in
            _ = try self.insertTranscript(db, audioPath: "/nonexistent.caf")
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadTrain()

        XCTAssertNil(center.lastError)
        XCTAssertTrue(center.groups.isEmpty)
    }

    /// A cluster shorter than `minClusterSpeechSec` never becomes a Train
    /// candidate; one with no recorded `speech_sec` at all (a legacy row) is
    /// included regardless (the same rule `VoiceRetroRelabeler` applies).
    func testShortClusterExcludedLegacyClusterWithNoSpeechSecIncluded() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await pool.write { db in
            try TestDatabase.insertMeetingTranscript(
                db, title: "Too short", audioPath: audio.path,
                transcriptText: TranscriptSegments.render(self.oneUtterance("Speaker 1")),
                segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(self.oneUtterance("Speaker 1"))),
                speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0],"clips":[{"start":1,"end":6}],"speech_sec":5}]"#)
            try TestDatabase.insertMeetingTranscript(
                db, title: "Legacy, no speech_sec", audioPath: audio.path,
                transcriptText: TranscriptSegments.render(self.oneUtterance("Speaker 1")),
                segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(self.oneUtterance("Speaker 1"))),
                speakersJSON: #"[{"speaker":"Speaker 1","embedding":[0,1],"clips":[{"start":1,"end":6}]}]"#)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadTrain()

        XCTAssertNil(center.lastError)
        XCTAssertEqual(center.groups.map(\.members.count), [1], "only the legacy, no-speech_sec cluster is a candidate")
    }

    // MARK: - loadTrain suggestion/hint

    /// Spec §4.2 step 3, the registry-match half: a group whose nearest
    /// registry person scores in `[unsureFloor, confident)` gets a "Looks
    /// like <name>, <score>" hint and that person pre-selected — never the
    /// attendee fallback.
    func testRegistryMatchHintWhenScoreIsInTheUnsureBandBelowConfident() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await pool.write { db in
            let alice = try VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice")
            var anchor = VoiceSample(
                personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode([1, 0]),
                modelVersion: VoiceRegistryPolicy.embeddingModelVersion, origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(db, &anchor)
            // cosine([1,0], [0.6,0.8]) == 0.6 — inside [unsureFloor 0.55, confident 0.70).
            _ = try self.insertTranscript(db, audioPath: audio.path, embedding: "[0.6,0.8]")
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadTrain()

        XCTAssertNil(center.lastError)
        let group = try XCTUnwrap(center.groups.first)
        XCTAssertEqual(group.hint, "Looks like Alice, 0.60")
        XCTAssertEqual(group.suggestion?.personKey, "alice@example.com")
        XCTAssertEqual(group.suggestion?.inRegistry, true)
    }

    /// A score at/above `confident` never offers the registry-match hint
    /// (spec §4.2: "close but BELOW confident" — a confidently-matching
    /// cluster would already have been retro-labeled, so it wouldn't be a
    /// Train candidate at all; this pins the upper bound as defense in depth).
    func testRegistryMatchAtOrAboveConfidentNeverOffersTheHint() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await pool.write { db in
            let alice = try VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice")
            var anchor = VoiceSample(
                personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode([1, 0]),
                modelVersion: VoiceRegistryPolicy.embeddingModelVersion, origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(db, &anchor)
            // Same vector as the anchor — cosine 1.0, well above `confident`.
            _ = try self.insertTranscript(db, audioPath: audio.path, embedding: "[1,0]")
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadTrain()

        XCTAssertNil(center.lastError)
        let group = try XCTUnwrap(center.groups.first)
        XCTAssertNotEqual(group.suggestion?.personKey, "alice@example.com", "a confident match must not be offered as the Train hint")
    }

    /// Spec §4.2 step 3, the attendee-fallback half: with no registry match
    /// at all, the group suggests the not-yet-registered attendee present at
    /// the most of its meetings.
    func testAttendeeFallbackSuggestionWhenNoRegistryMatch() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await pool.write { db in
            try TestDatabase.insertCalendarEvent(
                db, id: "evt-1", organizerEmail: "owner@example.com",
                attendees: #"[{"email":"dave@example.com","display_name":"Dave","response_status":"accepted","slack_user_id":""}]"#)
            _ = try self.insertTranscript(db, audioPath: audio.path, eventID: "evt-1")
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadTrain()

        XCTAssertNil(center.lastError)
        let group = try XCTUnwrap(center.groups.first)
        XCTAssertEqual(group.hint, "Was at 1 of 1 meetings")
        XCTAssertEqual(group.suggestion?.personKey, "dave@example.com")
        XCTAssertEqual(group.suggestion?.displayName, "Dave")
        XCTAssertEqual(group.suggestion?.inRegistry, false)
    }

    // MARK: - quality header

    /// After a `confirmGroup`, `TrainQuality` reflects the newly-owner-labeled
    /// cluster's speech (owner + named minutes), the new registry person, and
    /// their single captured channel.
    func testQualityReflectsOwnerMinutesAndPeopleAfterConfirmGroup() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await pool.write { db in
            try TestDatabase.insertMeetingTranscript(
                db, title: "Rec", audioPath: audio.path,
                transcriptText: TranscriptSegments.render(self.oneUtterance("Speaker 1")),
                segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(self.oneUtterance("Speaker 1"))),
                speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0],"clips":[{"start":1,"end":6}],"speech_sec":120,"channel":"room"}]"#)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadTrain()
        XCTAssertEqual(center.quality.people, 0, "no registry person yet")

        let group = try XCTUnwrap(center.groups.first)
        await center.confirmGroup(group, person: PersonChoice(personKey: "alice@example.com", displayName: "Alice", inRegistry: false))

        XCTAssertNil(center.lastError)
        XCTAssertEqual(center.quality.ownerMinutes, 2, accuracy: 0.001)
        XCTAssertEqual(center.quality.namedMinutes, 2, accuracy: 0.001)
        XCTAssertEqual(center.quality.autoMinutes, 0, accuracy: 0.001)
        XCTAssertEqual(center.quality.people, 1)
        XCTAssertEqual(center.quality.singleChannelPeople, 1)
    }

    // MARK: - confirmGroup

    /// One confirmation labels every member: the audio member goes through
    /// `VoiceLabelingQueries.confirm` (mints an owner anchor sample from its
    /// own embedding), the audio-less member is relabeled directly with no
    /// anchor of its own — there is no clip that vouched for it.
    func testConfirmGroupLabelsEveryMemberAndAnchorsOnlyFromAudio() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let (withAudio, withoutAudio) = try await pool.write { db -> (Int64, Int64) in
            let withAudio = try self.insertTranscript(db, title: "Has audio", audioPath: audio.path)
            let withoutAudio = try self.insertTranscript(db, title: "No audio", audioPath: "/nonexistent.caf")
            return (withAudio, withoutAudio)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadTrain()
        let group = try XCTUnwrap(center.groups.first)

        await center.confirmGroup(group, person: PersonChoice(personKey: "alice@example.com", displayName: "Alice", inRegistry: false))

        XCTAssertNil(center.lastError)

        let (withAudioCluster, withoutAudioCluster) = try await pool.read { db in
            (try self.cluster(db, transcriptID: withAudio), try self.cluster(db, transcriptID: withoutAudio))
        }
        XCTAssertEqual(withAudioCluster?.speaker, "Alice")
        XCTAssertEqual(withAudioCluster?.labelSource, VoiceLabelSource.owner)
        XCTAssertEqual(withoutAudioCluster?.speaker, "Alice")
        XCTAssertEqual(withoutAudioCluster?.labelSource, VoiceLabelSource.owner)
        XCTAssertNotNil(withoutAudioCluster?.personID)
        XCTAssertEqual(withAudioCluster?.personID, withoutAudioCluster?.personID, "both members name the same person")

        let (personCount, sampleCount, sampleTranscriptIDs) = try await pool.read { db in
            (try VoicePrint.fetchCount(db), try VoiceSample.fetchCount(db), try Int64.fetchAll(db, sql: "SELECT transcript_id FROM voice_samples"))
        }
        XCTAssertEqual(personCount, 1, "findOrCreate never double-creates the person")
        XCTAssertEqual(sampleCount, 1, "only the audio member minted an anchor")
        XCTAssertEqual(sampleTranscriptIDs, [withAudio])

        XCTAssertTrue(center.groups.isEmpty, "the group is fully resolved and regroups away")
    }

    /// A member relabeled by something else between `loadTrain` and this
    /// `confirmGroup` (simulating a race) comes back `.alreadyLabeled` from
    /// `VoiceLabelingQueries.confirm` — this must not be silently swallowed:
    /// the rest of the group still commits, and the miss is counted and
    /// surfaced as a partial-failure `lastError`.
    func testConfirmGroupPartialFailureSurfacesCountAndStillCommitsTheRest() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let (t1, t2) = try await pool.write { db -> (Int64, Int64) in
            let t1 = try self.insertTranscript(db, title: "A", audioPath: audio.path)
            let t2 = try self.insertTranscript(db, title: "B", audioPath: audio.path)
            return (t1, t2)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadTrain()
        let group = try XCTUnwrap(center.groups.first)
        XCTAssertEqual(group.members.count, 2, "same-voice fixtures across two transcripts merge")

        // Simulate a race: t2's cluster gets relabeled by something else
        // (e.g. a concurrent confirm elsewhere) between `loadTrain` and the
        // `confirmGroup` call below.
        try await pool.write { db in
            _ = try MeetingTranscriptQueries.relabelCluster(db, id: t2, from: "Speaker 1", to: "Bob")
        }

        await center.confirmGroup(group, person: PersonChoice(personKey: "alice@example.com", displayName: "Alice", inRegistry: false))

        XCTAssertEqual(center.lastError, "1 of 2 voices were already labeled")
        let (c1, c2) = try await pool.read { db in (try self.cluster(db, transcriptID: t1), try self.cluster(db, transcriptID: t2)) }
        XCTAssertEqual(c1?.speaker, "Alice", "the unaffected member still commits")
        XCTAssertEqual(c2?.speaker, "Bob", "the raced member is left as whatever relabeled it — never overwritten")
    }

    // MARK: - dismissGroup

    /// "Several people" marks every member of the group `mixed` — it never
    /// resurfaces as a candidate again, and is never learned from or relabeled
    /// (spec §4.2: dissolved, regrouped more strictly next time).
    func testDismissGroupSeveralPeopleMarksAllMembersMixed() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let (t1, t2) = try await pool.write { db -> (Int64, Int64) in
            let t1 = try self.insertTranscript(db, title: "A", audioPath: audio.path)
            let t2 = try self.insertTranscript(db, title: "B", audioPath: audio.path)
            return (t1, t2)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadTrain()
        let group = try XCTUnwrap(center.groups.first)
        XCTAssertEqual(group.members.count, 2, "same-voice fixtures across two transcripts merge")

        await center.dismissGroup(group, severalPeople: true)

        XCTAssertNil(center.lastError)
        let (c1, c2) = try await pool.read { db in (try self.cluster(db, transcriptID: t1), try self.cluster(db, transcriptID: t2)) }
        XCTAssertEqual(c1?.mixed, true)
        XCTAssertEqual(c1?.labelSource, VoiceLabelSource.owner)
        XCTAssertEqual(c1?.speaker, "Speaker 1", "the label itself is untouched")
        XCTAssertEqual(c2?.mixed, true)
        XCTAssertEqual(c2?.labelSource, VoiceLabelSource.owner)

        XCTAssertTrue(center.groups.isEmpty, "mixed clusters are never a candidate again")
    }

    /// "Don't know" marks every member owner-dismissed (keeps "Speaker N",
    /// stops resurfacing) WITHOUT flagging `mixed` — a plain "I don't
    /// recognize this" is not a claim that the cluster mixes several voices.
    func testDismissGroupDontKnowMarksOwnerWithoutMixed() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let t1 = try await pool.write { db in try self.insertTranscript(db, audioPath: audio.path) }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadTrain()
        let group = try XCTUnwrap(center.groups.first)

        await center.dismissGroup(group, severalPeople: false)

        XCTAssertNil(center.lastError)
        let cluster = try await pool.read { db in try self.cluster(db, transcriptID: t1) }
        XCTAssertEqual(cluster?.labelSource, VoiceLabelSource.owner)
        XCTAssertNil(cluster?.mixed)
        XCTAssertTrue(center.groups.isEmpty)
    }

    // MARK: - degenerate

    /// A center that was never attach()ed must no-op cleanly (the
    /// `VoiceRegistryCenterTests.testMethodsBeforeAttachAreNoops` precedent).
    func testTrainMethodsBeforeAttachAreNoops() async throws {
        let center = VoiceRegistryCenter()
        let group = VoiceRegistryCenter.TrainGroup(id: "x", members: [], audioMembers: [], suggestion: nil, hint: "", speechMin: 0)

        await center.loadTrain()
        await center.confirmGroup(group, person: PersonChoice(personKey: "a", displayName: "A", inRegistry: false))
        await center.dismissGroup(group, severalPeople: true)

        XCTAssertTrue(center.groups.isEmpty)
        XCTAssertNil(center.lastError)
    }
}
