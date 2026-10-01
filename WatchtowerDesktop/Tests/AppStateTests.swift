import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

// MARK: - AppState Tests
//
// AppState.initialize() resolves a real DB path (Constants.configPath /
// Constants.databasePath) and shells out to the real `watchtower` CLI binary
// (runCLIMigrations) — neither is injectable, so it can't be exercised
// hermetically from XCTest. Instead these tests call `wireMeetingRecorderLoaders`
// directly (it is non-`private` specifically so @testable import can reach it),
// handing it a test-only DatabasePool, mirroring what `initialize()` does after
// the real DB opens.

@MainActor
final class AppStateTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    // MARK: - wireMeetingRecorderLoaders

    /// The registry loader is the single wire the whole voice-naming feature
    /// hangs off — Center tests self-wire it, so only this test notices the
    /// production assignment disappearing. It must deliver usable samples
    /// only, the owner's people from google_accounts (any status, empty
    /// emails dropped), and the event's invited set including the organizer.
    func testRegistryLoaderBuildsSnapshotFromDB() async throws {
        let appState = AppState()
        appState.wireMeetingRecorderLoaders(dbPool: dbManager.dbPool)
        let ids = try await dbManager.dbPool.write { db -> (owner: Int64, alice: Int64, boss: Int64, stranger: Int64) in
            _ = try TestDatabase.insertGoogleAccount(db, email: "Owner@Example.com", status: "revoked")
            _ = try TestDatabase.insertGoogleAccount(db, email: "", status: "ok") // pre-consent row
            try TestDatabase.insertCalendarEvent(
                db, id: "evt-org",
                organizerEmail: "boss@example.com",
                attendees: #"[{"email":"alice@example.com","display_name":"Alice","response_status":"accepted","slack_user_id":""}]"#)
            // No human guests: an empty list, and a room-resource-only list.
            // The organizer joins only a non-empty human list.
            try TestDatabase.insertCalendarEvent(db, id: "evt-empty", organizerEmail: "boss@example.com", attendees: "[]")
            try TestDatabase.insertCalendarEvent(
                db, id: "evt-room", organizerEmail: "boss@example.com",
                attendees: #"[{"email":"room-6@resource.calendar.google.com","display_name":"Room 6","# // leak-check:allow
                    + #""response_status":"accepted","slack_user_id":""}]"#)
            let owner = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "owner@example.com", displayName: "Owner").id)
            let alice = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice").id)
            let boss = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "boss@example.com", displayName: "Boss").id)
            let stranger = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "stranger@example.com", displayName: "Stranger").id)
            for (person, status) in [(alice, VoiceSampleStatus.active), (alice, .retired)] {
                var sample = VoiceSample(personID: person, embedding: VoicePrintEmbedding.encode([1, 0]),
                                         modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                         origin: .owner, anchor: true, status: status)
                try VoiceSampleQueries.insert(db, &sample)
            }
            return (owner, alice, boss, stranger)
        }
        let loader = try XCTUnwrap(appState.meetingRecorderCenter.registryLoader)

        let loadedOrg = await loader("evt-org")
        let snapshot = try XCTUnwrap(loadedOrg)
        XCTAssertEqual(snapshot.samples.map(\.status), [.active], "retired samples never reach the matcher")
        XCTAssertEqual(Set(snapshot.people.keys), [ids.owner, ids.alice, ids.boss, ids.stranger])
        XCTAssertEqual(snapshot.ownerPersonIDs, [ids.owner])
        XCTAssertEqual(snapshot.invited, [ids.alice, ids.boss], "the organizer must be invited too")

        let loadedAdHoc = await loader(nil)
        let adHoc = try XCTUnwrap(loadedAdHoc)
        XCTAssertNil(adHoc.invited, "an ad-hoc recording has no invited set")
        let loadedMissing = await loader("evt-none")
        let missing = try XCTUnwrap(loadedMissing, "a swept event row is not a read failure")
        XCTAssertNil(missing.invited, "a swept event row degrades to ad-hoc matching, never a throw")
        for eventID in ["evt-empty", "evt-room"] {
            let loaded = await loader(eventID)
            let noGuests = try XCTUnwrap(loaded)
            XCTAssertNil(noGuests.invited,
                         "\(eventID): zero attendee identities is ad-hoc (nil), never an empty invite list")
        }
    }

    /// The writer persists queue tasks and auto samples against the saved
    /// transcript and reports the queued count.
    func testRegistryWriterPersistsTasksAndSamples() async throws {
        let appState = AppState()
        appState.wireMeetingRecorderLoaders(dbPool: dbManager.dbPool)
        let (transcriptID, personID) = try await dbManager.dbPool.write { db -> (Int64, Int64) in
            try TestDatabase.insertMeetingTranscript(db, title: "Sync")
            let tid = db.lastInsertedRowID
            let pid = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice").id)
            return (tid, pid)
        }
        let writer = try XCTUnwrap(appState.meetingRecorderCenter.registryWriter)
        let sample = VoiceSample(personID: personID, embedding: VoicePrintEmbedding.encode([1, 0]),
                                 modelVersion: VoiceRegistryPolicy.embeddingModelVersion, origin: .auto,
                                 anchor: false, status: .active, clusterLabel: "Alice", channel: .remote)
        let queued = await writer(transcriptID, VoiceIdentificationOutcome(
            tasks: [(label: "Speaker 1", reason: .unknown, personID: nil, score: 0.3)], autoSamples: [sample]))

        XCTAssertEqual(queued, 1)
        try await dbManager.dbPool.read { db in
            XCTAssertEqual(try VoiceLabelQueueQueries.pending(db, transcriptID: transcriptID).map(\.clusterLabel), ["Speaker 1"])
            let stored = try XCTUnwrap(VoiceSample.fetchOne(db))
            XCTAssertEqual(stored.transcriptID, transcriptID, "the writer stamps the saved transcript id")
            XCTAssertEqual(stored.origin, .auto)
        }
    }

    /// A failed write (unknown transcript → FK violation; GRDB enables
    /// foreign keys by default) reports 0 queued,
    /// never throws into the save path.
    func testRegistryWriterFailureReportsZero() async throws {
        let appState = AppState()
        appState.wireMeetingRecorderLoaders(dbPool: dbManager.dbPool)
        let writer = try XCTUnwrap(appState.meetingRecorderCenter.registryWriter)
        let queued = await writer(9_999, VoiceIdentificationOutcome(
            tasks: [(label: "Speaker 1", reason: .unknown, personID: nil, score: nil)], autoSamples: []))
        XCTAssertEqual(queued, 0)
    }

    // MARK: - voice registry (savedTick wiring)

    /// `handleMeetingRecorderSaved` is the exact method AppState's
    /// `savedTick` Observation-tracking calls on every meeting-recorder
    /// save. Spec §4.1: retro's three triggers are an owner confirmation, an
    /// import person activated, and app launch — a save is none of those, so
    /// this must never relabel a cluster even when an active sample would
    /// confidently match it (that's `catchUp`'s job, at launch only).
    func testHandleMeetingRecorderSavedNeverRunsRetro() async throws {
        let appState = AppState()
        appState.voiceRegistryCenter.attach(dbPool: dbManager.dbPool)

        // `relabelCluster` (which retro relies on) requires a decodable
        // `segments_json` containing an utterance for the cluster's label —
        // the D1 invariant that keeps transcript text in sync with a label.
        let utterances = [TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Speaker 1", text: "hi")]
        let t1 = try await dbManager.dbPool.write { db -> Int64 in
            try TestDatabase.insertMeetingTranscript(
                db, transcriptText: TranscriptSegments.render(utterances),
                segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(utterances)),
                speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
            let t1 = db.lastInsertedRowID
            let alice = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice").id)
            var sample = VoiceSample(personID: alice, embedding: VoicePrintEmbedding.encode([1, 0]),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(db, &sample)
            return t1
        }

        await appState.handleMeetingRecorderSaved()

        let speaker = try await dbManager.dbPool.read { db in
            try MeetingTranscriptQueries.fetch(db, id: t1)?.speakerEmbeddings?.first?.speaker
        }
        XCTAssertEqual(speaker, "Speaker 1", "a save tick must never run the full retro pass")

        // The launch pass (`catchUp`, never wired to `savedTick`) DOES run
        // retro — proving the two are genuinely different, not just an
        // untriggered no-op.
        await appState.voiceRegistryCenter.catchUp()
        let relabeled = try await dbManager.dbPool.read { db in
            try MeetingTranscriptQueries.fetch(db, id: t1)?.speakerEmbeddings?.first?.speaker
        }
        XCTAssertEqual(relabeled, "Alice")
    }

    // MARK: - owner (OWNER-02 empty state)

    /// Day Plan / Briefings gate Generate on `owner`: it starts unknown, and a
    /// refresh resolves it through `OwnerQueries.resolve` (Google-only here —
    /// a no-Slack install must come out known).
    func testOwner02RefreshOwnerResolvesFromDB() async throws {
        let appState = AppState()
        appState.databaseManager = dbManager
        await appState.refreshOwner()
        XCTAssertEqual(appState.owner, .unknown)

        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "Me@Example.com")
        }
        await appState.refreshOwner()

        XCTAssertTrue(appState.owner.isKnown)
        XCTAssertEqual(appState.owner.id, "google:me@example.com")
        XCTAssertEqual(appState.owner.source, .google)
    }

    /// Connecting an account re-resolves the owner through the accounts VM's
    /// reload hook, with no screen having to ask.
    func testOwner02AccountReloadRefreshesOwner() async throws {
        let appState = AppState()
        appState.databaseManager = dbManager
        appState.initSlackAccounts(dbPool: dbManager.dbPool)
        let vm = try XCTUnwrap(appState.slackAccountsViewModel)
        await vm.refreshAsync()
        XCTAssertEqual(appState.owner, .unknown)

        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, teamID: "T1", currentUserID: "1:U1")
        }
        await vm.refreshAsync()

        XCTAssertEqual(appState.owner.id, "1:U1")
        XCTAssertEqual(appState.owner.source, .slack)
    }

    /// The Google accounts VM's reload hook re-resolves the owner too.
    func testOwner02GoogleAccountReloadRefreshesOwner() async throws {
        let appState = AppState()
        appState.databaseManager = dbManager
        appState.initGoogleAccounts(dbPool: dbManager.dbPool)
        let vm = try XCTUnwrap(appState.googleAccountsViewModel)
        await vm.refreshAsync()
        XCTAssertEqual(appState.owner, .unknown)

        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@x.com")
        }
        await vm.refreshAsync()

        XCTAssertEqual(appState.owner.id, "google:me@x.com")
        XCTAssertEqual(appState.owner.source, .google)
    }

    /// The Jira accounts VM's reload hook re-resolves the owner too.
    func testOwner02JiraAccountReloadRefreshesOwner() async throws {
        let appState = AppState()
        appState.databaseManager = dbManager
        appState.initJiraAccounts(dbPool: dbManager.dbPool)
        let vm = try XCTUnwrap(appState.jiraAccountsViewModel)
        await vm.refreshAsync()
        XCTAssertEqual(appState.owner, .unknown)

        try await dbManager.dbPool.write { db in
            let id = try TestDatabase.insertJiraAccount(db, cloudID: "c1")
            try db.execute(
                sql: "UPDATE jira_accounts SET owner_account_id = 'acc-9' WHERE id = ?",
                arguments: [id]
            )
        }
        await vm.refreshAsync()

        XCTAssertEqual(appState.owner.id, "jira:acc-9")
        XCTAssertEqual(appState.owner.source, .jira)
    }
}
