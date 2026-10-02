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
        let appState = AppState.isolated()
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
        let appState = AppState.isolated()
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
        let appState = AppState.isolated()
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
        let appState = AppState.isolated()
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
        let appState = AppState.isolated()
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
        let appState = AppState.isolated()
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

    /// Connecting a source in Settings shows its tabs at once: the account
    /// VMs' reload hook re-reads the connected sources.
    func testCalendarAndJiraReloadsRefreshConnectedSources() async throws {
        let appState = AppState.isolated()
        appState.databaseManager = dbManager
        appState.initCalendarAccounts(dbPool: dbManager.dbPool)
        appState.initJiraAccounts(dbPool: dbManager.dbPool)
        let calendar = try XCTUnwrap(appState.calendarAccountsViewModel)
        let jira = try XCTUnwrap(appState.jiraAccountsViewModel)

        try await dbManager.dbPool.write { db in _ = try TestDatabase.insertCalendarAccount(db) }
        await calendar.refreshAsync()
        XCTAssertEqual(appState.featureVisibility.connectedSources, ConnectedSources(calendar: true))

        try await dbManager.dbPool.write { db in _ = try TestDatabase.insertJiraAccount(db, cloudID: "c1") }
        await jira.refreshAsync()
        XCTAssertEqual(appState.featureVisibility.connectedSources, ConnectedSources(calendar: true, jira: true))
    }

    func testRemovedSlackAccountNoLongerCounts() async throws {
        let appState = AppState.isolated()
        appState.databaseManager = dbManager
        appState.initSlackAccounts(dbPool: dbManager.dbPool)
        let slack = try XCTUnwrap(appState.slackAccountsViewModel)
        let id = try await dbManager.dbPool.write { db in try TestDatabase.insertSlackAccount(db, teamID: "T1") }
        await slack.refreshAsync()
        XCTAssertTrue(appState.featureVisibility.connectedSources.slack)

        try await dbManager.dbPool.write { db in
            try db.execute(sql: "UPDATE slack_accounts SET status = 'removed' WHERE id = ?", arguments: [id])
        }
        await slack.refreshAsync()
        XCTAssertFalse(appState.featureVisibility.connectedSources.slack)
    }

    /// An existing DB with no accounts; onboarding connects Slack (through
    /// the CLI, no VM reload); completion re-reads the sources, so Inbox
    /// shows right away.
    func testCompleteOnboardingRefreshesConnectedSources() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(onboardingDefaults: defaults)
        appState.wireAppDatabaseOverride = { _ in }
        appState.databaseManager = dbManager
        await appState.refreshConnectedSources()
        XCTAssertFalse(SidebarDestination.inbox.isVisible(
            disabledFeatures: [], connected: appState.featureVisibility.connectedSources
        ))

        try await dbManager.dbPool.write { db in _ = try TestDatabase.insertSlackAccount(db, teamID: "T1") }
        appState.completeOnboarding()
        await appState.connectedSourcesRefresh?.value

        XCTAssertTrue(SidebarDestination.inbox.isVisible(
            disabledFeatures: [], connected: appState.featureVisibility.connectedSources
        ))
    }

    func testAccountReloadRefreshesConnectedSources() async throws {
        let appState = AppState.isolated()
        appState.databaseManager = dbManager
        appState.initSlackAccounts(dbPool: dbManager.dbPool)
        appState.initEmailAccounts(dbPool: dbManager.dbPool)
        let slack = try XCTUnwrap(appState.slackAccountsViewModel)
        let mail = try XCTUnwrap(appState.emailAccountsViewModel)
        await slack.refreshAsync()
        XCTAssertEqual(appState.featureVisibility.connectedSources, .none)

        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, teamID: "T1", currentUserID: "1:U1")
        }
        await slack.refreshAsync()
        XCTAssertEqual(appState.featureVisibility.connectedSources, ConnectedSources(slack: true))

        try await dbManager.dbPool.write { db in _ = try TestDatabase.insertEmailAccount(db) }
        await mail.refreshAsync()
        XCTAssertEqual(appState.featureVisibility.connectedSources, ConnectedSources(slack: true, mail: true))
    }

    /// The Google accounts VM's reload hook re-resolves the owner too.
    func testOwner02GoogleAccountReloadRefreshesOwner() async throws {
        let appState = AppState.isolated()
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
        let appState = AppState.isolated()
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

    // MARK: - Onboarding launch state

    private func onboardingSuite() throws -> (UserDefaults, String) {
        let name = "AppStateTests.onboarding.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    /// Launch with this suite and DB: the state `initialize()` derives after
    /// the DB opened (or, with `db: nil`, failed to).
    private func launch(_ defaults: UserDefaults, db: DatabaseManager?) async -> AppState {
        let appState = AppState(onboardingDefaults: defaults)
        appState.wireAppDatabaseOverride = { _ in }
        appState.databaseManager = db
        await appState.refreshConnectedSources()
        await appState.reconcileOnboarding(dbPool: db?.dbPool)
        return appState
    }

    private func screen(_ appState: AppState) -> NavigationRoot.Screen {
        NavigationRoot.screen(isLoading: false, ambiguousWorkspaces: [], needsOnboarding: appState.needsOnboarding)
    }

    /// GUARD: no UserDefaults at all (a new Mac, a wiped defaults domain) on
    /// an install whose DB says onboarding is done opens the main window —
    /// never onboarding again.
    func testNoLocalKeysAndOnboardingDoneInDBOpensMainWindow() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@example.com")
            try TestDatabase.insertProfile(db, slackUserID: "google:me@example.com", onboardingDone: true)
        }

        let appState = await launch(defaults, db: dbManager)

        XCTAssertEqual(appState.onboarding.currentStep, .complete)
        XCTAssertEqual(screen(appState), .main)
        XCTAssertEqual(defaults.string(forKey: OnboardingStateMachineV2.stepKey), "complete")
    }

    func testFreshInstallOpensGoals() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appState = await launch(defaults, db: dbManager)

        XCTAssertEqual(appState.onboarding.currentStep, .purpose)
        XCTAssertEqual(screen(appState), .onboarding)
    }

    func testFreshInstallWithoutADatabaseOpensGoals() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appState = await launch(defaults, db: nil)

        XCTAssertEqual(appState.onboarding.currentStep, .purpose)
        XCTAssertEqual(screen(appState), .onboarding)
    }

    /// The legacy `onboarding_current_step` mapping holds through AppState:
    /// 7 (complete) → main window even with no profile row; a mid-way step
    /// starts over at Goals.
    func testLegacyCompleteStepOpensMainWindow() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(7, forKey: OnboardingStateMachineV2.legacyStepKey)

        let appState = await launch(defaults, db: dbManager)

        XCTAssertEqual(screen(appState), .main)
        XCTAssertNil(defaults.object(forKey: OnboardingStateMachineV2.legacyStepKey))
    }

    func testLegacyMidwayStepStartsOverAtGoals() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(3, forKey: OnboardingStateMachineV2.legacyStepKey)

        let appState = await launch(defaults, db: dbManager)

        XCTAssertEqual(appState.onboarding.currentStep, .purpose)
        XCTAssertEqual(screen(appState), .onboarding)
    }

    /// A relaunch on Connect after the saved goals became Development only
    /// moves on to About you when Slack is connected.
    func testLaunchSettlesASkippedStep() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(OnboardingV2Step.connect.rawValue, forKey: OnboardingStateMachineV2.stepKey)
        defaults.set(["development"], forKey: OnboardingGoalsModel.goalsKey)
        try await dbManager.dbPool.write { db in _ = try TestDatabase.insertSlackAccount(db, teamID: "T1") }

        let appState = await launch(defaults, db: dbManager)

        XCTAssertEqual(appState.onboarding.currentStep, .aboutYou)
    }

    /// With nothing left after the skipped step, launch goes back to Goals
    /// rather than to `.complete`: Goals' Continue runs the completion
    /// sequence that writes `onboarding_done`.
    func testLaunchNeverSettlesPastTheCompletionSequence() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(OnboardingV2Step.aboutYou.rawValue, forKey: OnboardingStateMachineV2.stepKey)

        let appState = await launch(defaults, db: dbManager)

        XCTAssertEqual(appState.onboarding.currentStep, .purpose)
        XCTAssertEqual(screen(appState), .onboarding)
    }

    /// Run setup again: back to Goals, and the pipelines rerun afterwards.
    func testStartOnboardingResetsToGoalsAndClearsPipelinesFlag() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removeObject(forKey: Constants.pipelinesCompletedKey)
        }
        defaults.set(7, forKey: OnboardingStateMachineV2.legacyStepKey)
        let appState = await launch(defaults, db: dbManager)
        UserDefaults.standard.set(true, forKey: Constants.pipelinesCompletedKey)

        appState.startOnboarding()

        XCTAssertEqual(appState.onboarding.currentStep, .purpose)
        XCTAssertTrue(appState.needsOnboarding)
        XCTAssertNil(UserDefaults.standard.object(forKey: Constants.pipelinesCompletedKey))
    }

    func testLegacyCompleteStepWithoutADatabaseOpensMainWindow() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(7, forKey: OnboardingStateMachineV2.legacyStepKey)

        let appState = await launch(defaults, db: nil)

        XCTAssertEqual(screen(appState), .main)
    }

    /// An unreadable profile opens the main window for this launch but is
    /// not taken as "done": the next launch checks again.
    func testUnreadableProfileSkipsOnboardingForThisLaunchOnly() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await dbManager.dbPool.write { db in try db.execute(sql: "DROP TABLE slack_accounts") }

        let appState = await launch(defaults, db: dbManager)

        XCTAssertEqual(screen(appState), .main)
        XCTAssertEqual(appState.onboarding.currentStep, .purpose)
        XCTAssertEqual(defaults.string(forKey: OnboardingStateMachineV2.stepKey), "purpose")
    }

    func testStartOnboardingResetsTheGoalsStep() async throws {
        let (defaults, suiteName) = try onboardingSuite()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removeObject(forKey: Constants.pipelinesCompletedKey)
        }
        let appState = await launch(defaults, db: dbManager)
        appState.onboardingGoals.isCustomizingFeatures = true

        appState.startOnboarding()

        XCTAssertFalse(appState.onboardingGoals.isCustomizingFeatures)
        XCTAssertEqual(appState.onboardingGoals.cliCheck, .checking)
        XCTAssertNil(appState.onboardingStepError)
    }

    // MARK: - Onboarding Connect wiring

    /// Records each people-load launch; finishes at once.
    @MainActor
    private final class RosterLaunches {
        var accounts: [Int] = []
    }

    /// Spins the main actor until `condition` holds (bounded).
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    private func onboardingAppState(_ launches: RosterLaunches) -> AppState {
        let run: PeopleRosterLoad.Run = { accountID, _ in
            await MainActor.run { launches.accounts.append(accountID) }
            return (0, "")
        }
        let appState = AppState.isolated(peopleRosterRun: run)
        appState.databaseManager = dbManager
        appState.needsOnboarding = true
        return appState
    }

    /// The connect lands after its sheet was closed (mid-sign-in): the
    /// account list refresh it ends with starts the load, exactly once.
    func testNewSlackAccountStartsThePeopleLoadOnce() async throws {
        let launches = RosterLaunches()
        let appState = onboardingAppState(launches)
        appState.initSlackAccounts(dbPool: dbManager.dbPool)
        let vm = try XCTUnwrap(appState.slackAccountsViewModel)
        await vm.refreshAsync()

        let id = try await dbManager.dbPool.write { db in try TestDatabase.insertSlackAccount(db, teamID: "T1") }
        await vm.refreshAsync()
        await waitUntil { launches.accounts.count == 1 }
        await vm.refreshAsync()
        await appState.peopleRoster.waitForCompletion()

        XCTAssertEqual(launches.accounts, [Int(id)])
    }

    /// Closing the Google (or Jira) sheet with Slack already connected
    /// refreshes nothing new on the Slack side: no load.
    func testAlreadyConnectedSlackStartsNothing() async throws {
        let launches = RosterLaunches()
        let appState = onboardingAppState(launches)
        try await dbManager.dbPool.write { db in _ = try TestDatabase.insertSlackAccount(db, teamID: "T1") }
        appState.initSlackAccounts(dbPool: dbManager.dbPool)
        let vm = try XCTUnwrap(appState.slackAccountsViewModel)
        await vm.refreshAsync()
        await vm.refreshAsync()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(launches.accounts, [])
    }

    func testSlackAccountOutsideOnboardingStartsNothing() async throws {
        let launches = RosterLaunches()
        let appState = onboardingAppState(launches)
        appState.needsOnboarding = false
        appState.slackAccountsDidChange([])
        let id = try await dbManager.dbPool.write { db in try TestDatabase.insertSlackAccount(db, teamID: "T1") }
        let accounts = try await dbManager.dbPool.read { db in try SlackAccountQueries.fetchAll(db) }
        XCTAssertEqual(accounts.map(\.id), [Int(id)])

        appState.slackAccountsDidChange(accounts)

        XCTAssertEqual(appState.peopleRoster.state, .idle)
    }

    /// A relaunch on Connect / About you: the connected account's load runs
    /// once.
    func testResumePeopleRosterStartsOnceForAConnectedAccount() async throws {
        let launches = RosterLaunches()
        let appState = onboardingAppState(launches)
        try await dbManager.dbPool.write { db in _ = try TestDatabase.insertSlackAccount(db, teamID: "T1") }
        appState.initSlackAccounts(dbPool: dbManager.dbPool)
        await appState.slackAccountsViewModel?.refreshAsync()

        appState.resumePeopleRosterIfNeeded()
        await appState.peopleRoster.waitForCompletion()
        appState.resumePeopleRosterIfNeeded()

        XCTAssertEqual(launches.accounts.count, 1)
    }

    // MARK: - Onboarding database and finish

    /// Counts opens; returns the test database.
    private final class OpenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
    }

    func testOpenDatabaseForOnboardingIsANoOpWhenOpen() async throws {
        let opens = OpenCounter()
        let manager = try XCTUnwrap(dbManager)
        let open: @Sendable () throws -> DatabaseManager = { opens.bump(); return manager }
        let appState = AppState.isolated(openDatabase: open)
        appState.databaseManager = dbManager

        let failure = await appState.openDatabaseForOnboarding()

        XCTAssertNil(failure)
        XCTAssertEqual(opens.count, 0)
    }

    func testConcurrentOpensShareOneOpen() async throws {
        let opens = OpenCounter()
        let manager = try XCTUnwrap(dbManager)
        let open: @Sendable () throws -> DatabaseManager = { opens.bump(); return manager }
        let appState = AppState.isolated(openDatabase: open)

        async let first = appState.openDatabaseForOnboarding()
        async let second = appState.openDatabaseForOnboarding()
        let results = await [first, second]

        XCTAssertEqual(results, [nil, nil])
        XCTAssertEqual(opens.count, 1)
        XCTAssertNotNil(appState.slackAccountsViewModel, "the Connect sheets' view models are built")
        XCTAssertNil(appState.calendarViewModel, "the rest waits for completion")
    }

    func testFailedOpenIsReported() async {
        let appState = AppState.isolated()
        let failure = await appState.openDatabaseForOnboarding()
        XCTAssertNotNil(failure)
        XCTAssertNil(appState.databaseManager)
    }

    /// Fresh install: Goals opened the DB for Connect; leaving the last
    /// step still runs the whole completion sequence, pipelines included,
    /// and wires the rest of the app once.
    func testFinishAfterTheOnboardingOpenReachesThePipelines() async throws {
        let manager = try XCTUnwrap(dbManager)
        let open: @Sendable () throws -> DatabaseManager = { manager }
        let appState = AppState.isolated(openDatabase: open)
        var pipelineStarts = 0
        var appWirings = 0
        var retries = 0
        appState.startOnboardingPipelinesOverride = { pipelineStarts += 1 }
        appState.wireAppDatabaseOverride = { _ in appWirings += 1 }
        appState.needsOnboarding = true
        let openFailure = await appState.openDatabaseForOnboarding()
        XCTAssertNil(openFailure)

        let route = OnboardingRoute(goals: [.tasksAndJira], hasSlackAccount: false)
        appState.onboarding.goTo(.connect)
        await appState.leaveOnboardingStep(.connect, route: route) { retries += 1 }

        XCTAssertEqual(pipelineStarts, 1)
        XCTAssertEqual(appWirings, 1)
        XCTAssertEqual(retries, 1)
        XCTAssertFalse(appState.needsOnboarding)
        XCTAssertEqual(appState.onboarding.currentStep, .complete)
        XCTAssertNil(appState.onboardingStepError)
        let done = try await dbManager.dbPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT onboarding_done FROM user_profile LIMIT 1")
        }
        XCTAssertEqual(done, true)
    }
}
