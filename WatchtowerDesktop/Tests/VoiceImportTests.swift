import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// `VoiceExportCodec` round-trip/tamper coverage lives in
/// `Tests/Core/VoiceExportCodecTests.swift` — this file covers the DB side
/// (design spec §5): what `buildExport`/`preview`/`apply` actually write.
final class VoiceImportTests: XCTestCase {
    private func encode(_ x: Float, _ y: Float) -> Data { VoicePrintEmbedding.encode([x, y]) }

    private let colleagueA = VoiceExportPayload.Sender(name: "Colleague A", email: "a@example.com")

    /// One imported person with a single 2-dimensional sample — keeps every
    /// test's payload literal to one short line.
    private func person(
        _ key: String,
        _ name: String,
        _ x: Float,
        _ y: Float,
        channel: VoiceChannel = .remote,
        speechSec: Double = 40
    ) -> VoiceExportPayload.Person {
        .init(personKey: key, displayName: name, samples: [.init(embedding: [x, y], channel: channel, speechSec: speechSec)])
    }

    private func samplesFor(_ conn: Database, personID: Int64) throws -> [VoiceSample] {
        try VoiceSample.filter(Column("person_id") == personID).fetchAll(conn)
    }

    // MARK: - Export

    func testExportExcludesImportedAndCapsPerChannel() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let person = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let personID = try XCTUnwrap(person.id)

            var owner = VoiceSample(
                personID: personID, embedding: self.encode(1, 0), modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                origin: .owner, anchor: true, status: .active, channel: .room, speechSec: 30)
            try VoiceSampleQueries.insert(conn, &owner)

            for i in 0..<7 {
                _ = try VoiceSampleQueries.insertAuto(conn, VoiceSample(
                    personID: personID, embedding: self.encode(Float(i) + 1, 1), modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                    origin: .auto, anchor: false, status: .active, channel: .remote, score: Float(i) / 10, speechSec: 30))
            }

            var imported = VoiceSample(
                personID: personID, embedding: self.encode(50, 1), modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                origin: .imported, anchor: false, status: .active, channel: .room, speechSec: 999)
            try VoiceSampleQueries.insert(conn, &imported)

            let payload = try VoiceImportQueries.buildExport(conn, sender: self.colleagueA, personIDs: [personID])
            let exported = try XCTUnwrap(payload.people.first)
            XCTAssertFalse(exported.samples.contains { $0.speechSec == 999 }, "an imported sample is never re-exported (invariant 4)")
            XCTAssertLessThanOrEqual(
                exported.samples.filter { $0.channel == .remote }.count, VoiceRegistryPolicy.exportPerChannel)
        }
    }

    // MARK: - Import

    func testImportPendingAndMergeByEmailKeepsLocalDisplayName() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            // DB B already knows Alice under its own display name.
            _ = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice (B's name)")

            let payload = VoiceExportPayload(
                formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion, sender: self.colleagueA,
                people: [self.person("alice@example.com", "Alice (A's name)", 1, 0)])

            let importID = try VoiceImportQueries.apply(conn, payload: payload, fileSHA256: "sha-merge", ownerEmails: [])
            XCTAssertNotNil(importID)

            let person = try XCTUnwrap(VoicePrintQueries.fetch(conn, personKey: "alice@example.com"))
            XCTAssertEqual(person.displayName, "Alice (B's name)", "the local display name wins")
            XCTAssertEqual(try VoicePrint.fetchCount(conn), 1, "merged, not duplicated")

            let samples = try self.samplesFor(conn, personID: try XCTUnwrap(person.id))
            XCTAssertEqual(samples.count, 1)
            XCTAssertEqual(samples[0].status, .pending)
            XCTAssertEqual(samples[0].origin, .imported)
        }
    }

    func testOwnerEmailSkippedOnImport() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let payload = VoiceExportPayload(
                formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion, sender: self.colleagueA,
                people: [self.person("owner@example.com", "Owner", 1, 0, channel: .room, speechSec: 20)])

            let preview = try VoiceImportQueries.preview(conn, payload: payload, fileSHA256: "sha-owner", ownerEmails: ["owner@example.com"])
            XCTAssertEqual(preview.skippedOwner, 1)
            XCTAssertEqual(preview.people, 0)

            let importID = try VoiceImportQueries.apply(conn, payload: payload, fileSHA256: "sha-owner", ownerEmails: ["owner@example.com"])
            XCTAssertNotNil(importID, "the file still logs — it's neither a duplicate nor a mismatch")
            XCTAssertNil(try VoicePrintQueries.fetch(conn, personKey: "owner@example.com"))
            XCTAssertEqual(try VoiceSample.fetchCount(conn), 0)
        }
    }

    /// Invariant 2: reserved labels («Я», "Speaker N") never become people.
    func testReservedNamesSkippedOnImport() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let payload = VoiceExportPayload(
                formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion, sender: self.colleagueA,
                people: [self.person("я", "Я", 1, 0), self.person("speaker 3", "Speaker 3", 0, 1),
                         self.person("bob@example.com", "Bob", 1, 1)])

            let preview = try VoiceImportQueries.preview(conn, payload: payload, fileSHA256: "sha-res", ownerEmails: [])
            XCTAssertEqual(preview.skippedOwner, 2)
            XCTAssertEqual(preview.newPeople, ["Bob"])

            XCTAssertNotNil(try VoiceImportQueries.apply(conn, payload: payload, fileSHA256: "sha-res", ownerEmails: []))
            XCTAssertEqual(try VoicePrintQueries.fetchAll(conn).map(\.displayName), ["Bob"])
            XCTAssertEqual(try VoiceSample.fetchCount(conn), 1)
        }
    }

    /// Spec §5 export selection: per person+channel, anchors first, then the
    /// highest-scoring auto samples, capped at `exportPerChannel`.
    func testExportTakesAnchorsFirstThenTopScoringAuto() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let person = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let personID = try XCTUnwrap(person.id)
            var anchor = VoiceSample(
                personID: personID, embedding: self.encode(1, 0), modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                origin: .owner, anchor: true, status: .active, channel: .remote, speechSec: 30)
            try VoiceSampleQueries.insert(conn, &anchor)
            // Auto samples x = 2…8 with scores 0.0…0.6, inserted low → high.
            for i in 0..<7 {
                _ = try VoiceSampleQueries.insertAuto(conn, VoiceSample(
                    personID: personID, embedding: self.encode(Float(i) + 2, 1), modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                    origin: .auto, anchor: false, status: .active, channel: .remote, score: Float(i) / 10, speechSec: 30))
            }

            let payload = try VoiceImportQueries.buildExport(conn, sender: self.colleagueA, personIDs: [personID])
            // Vectors export normalized: the anchor is [1, 0]; an auto sample
            // is identified by its x/y ratio (= the x it was stored with).
            let exported = try XCTUnwrap(payload.people.first).samples.map(\.embedding)
            XCTAssertEqual(exported.first, [1, 0], "the anchor comes first")
            XCTAssertEqual(exported.dropFirst().map { ($0[0] / $0[1]).rounded() }, [8, 7, 6, 5],
                           "then the four best-scoring auto samples, best first")
        }
    }

    func testSameFileTwiceReturnsNilAndWritesNothing() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let payload = VoiceExportPayload(
                formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion, sender: self.colleagueA,
                people: [self.person("bob@example.com", "Bob", 1, 0)])

            XCTAssertNotNil(try VoiceImportQueries.apply(conn, payload: payload, fileSHA256: "dup-sha", ownerEmails: []))
            let sampleCountAfterFirst = try VoiceSample.fetchCount(conn)

            XCTAssertNil(try VoiceImportQueries.apply(conn, payload: payload, fileSHA256: "dup-sha", ownerEmails: []))
            XCTAssertEqual(try VoiceSample.fetchCount(conn), sampleCountAfterFirst, "the second apply wrote nothing")
            XCTAssertEqual(try VoiceImport.fetchCount(conn), 1)
        }
    }

    func testNewerFileFromSameSenderReplacesPendingKeepsActivated() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let firstPayload = VoiceExportPayload(
                formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion, sender: self.colleagueA,
                people: [self.person("alice@example.com", "Alice", 1, 0), self.person("bob@example.com", "Bob", 0, 1)])
            XCTAssertNotNil(try VoiceImportQueries.apply(conn, payload: firstPayload, fileSHA256: "sha-1", ownerEmails: []))

            // The owner confirms Alice's imported voice from the first file.
            let alice = try XCTUnwrap(VoicePrintQueries.fetch(conn, personKey: "alice@example.com"))
            let aliceID = try XCTUnwrap(alice.id)
            try VoiceSampleQueries.activatePending(conn, personID: aliceID, importID: nil)

            let secondPayload = VoiceExportPayload(
                formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion, sender: self.colleagueA,
                people: [self.person("carol@example.com", "Carol", 1, 1)])
            XCTAssertNotNil(try VoiceImportQueries.apply(conn, payload: secondPayload, fileSHA256: "sha-2", ownerEmails: []))

            let bob = try XCTUnwrap(VoicePrintQueries.fetch(conn, personKey: "bob@example.com"))
            let bobSamples = try self.samplesFor(conn, personID: try XCTUnwrap(bob.id))
            XCTAssertTrue(bobSamples.isEmpty, "Bob's stale pending sample from the first file is replaced away")

            let aliceSamples = try self.samplesFor(conn, personID: aliceID)
            XCTAssertEqual(aliceSamples.count, 1)
            XCTAssertEqual(aliceSamples[0].status, .active, "the confirmed sample survives the resend")

            let carol = try XCTUnwrap(VoicePrintQueries.fetch(conn, personKey: "carol@example.com"))
            XCTAssertEqual(try self.samplesFor(conn, personID: try XCTUnwrap(carol.id)).count, 1)
        }
    }

    /// Two senders without an email (e.g. Jira-only owners) are not "the
    /// same sender" — the second file must not wipe the first one's samples.
    func testEmptySenderEmailNeverReplacesAnotherSendersPendingSamples() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let first = VoiceExportPayload(
                formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                sender: .init(name: "Colleague A", email: ""), people: [self.person("alice@example.com", "Alice", 1, 0)])
            XCTAssertNotNil(try VoiceImportQueries.apply(conn, payload: first, fileSHA256: "sha-1", ownerEmails: []))
            let second = VoiceExportPayload(
                formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                sender: .init(name: "Colleague B", email: "  "), people: [self.person("bob@example.com", "Bob", 0, 1)])
            XCTAssertNotNil(try VoiceImportQueries.apply(conn, payload: second, fileSHA256: "sha-2", ownerEmails: []))

            let alice = try XCTUnwrap(VoicePrintQueries.fetch(conn, personKey: "alice@example.com"))
            XCTAssertEqual(try self.samplesFor(conn, personID: try XCTUnwrap(alice.id)).map(\.status), [.pending],
                           "Colleague A's suggestion survives Colleague B's file")
        }
    }

    func testModelMismatchFlaggedInPreviewAndBlocksApply() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let payload = VoiceExportPayload(
                formatVersion: 1, modelVersion: "some-older-model", sender: self.colleagueA,
                people: [self.person("dave@example.com", "Dave", 1, 0, channel: .room)])

            let preview = try VoiceImportQueries.preview(conn, payload: payload, fileSHA256: "sha-mismatch", ownerEmails: [])
            XCTAssertTrue(preview.modelMismatch)

            XCTAssertNil(try VoiceImportQueries.apply(conn, payload: payload, fileSHA256: "sha-mismatch", ownerEmails: []))
            XCTAssertEqual(try VoiceImport.fetchCount(conn), 0)
            XCTAssertEqual(try VoiceSample.fetchCount(conn), 0)
        }
    }

    func testImportedSampleConflictingWithADifferentLocalPersonAppearsInPreview() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let existing = try VoicePrintQueries.findOrCreate(conn, personKey: "erin@example.com", displayName: "Erin")
            var erinSample = VoiceSample(
                personID: try XCTUnwrap(existing.id), embedding: self.encode(1, 0), modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                origin: .owner, anchor: true, status: .active, channel: .room, speechSec: 30)
            try VoiceSampleQueries.insert(conn, &erinSample)

            // Frank is a different person in the imported file whose voice happens to match Erin's.
            let payload = VoiceExportPayload(
                formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion, sender: self.colleagueA,
                people: [self.person("frank@example.com", "Frank", 1, 0.001, channel: .room, speechSec: 30)])

            let preview = try VoiceImportQueries.preview(conn, payload: payload, fileSHA256: "sha-conflict", ownerEmails: [])
            XCTAssertFalse(preview.conflicts.isEmpty)
            XCTAssertTrue(preview.conflicts.contains { $0.contains("Erin") })
        }
    }
}
