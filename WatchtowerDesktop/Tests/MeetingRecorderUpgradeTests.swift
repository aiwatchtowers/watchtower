import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The upgrade from the sidecar build (#604 S3/S4): an older build kept a
/// recording pending exactly while its `rec_X.meta` existed, and that rule
/// survives the move into `pending_transcripts`. Also the launch prune and the
/// record-start order.
@MainActor
final class MeetingRecorderUpgradeTests: MeetingRecorderTestCase {
    private func center(
        store: PendingTranscriptStore? = nil,
        defaults: UserDefaults? = nil,
        recorder: FakeRecorder = FakeRecorder()
    ) throws -> MeetingRecorderCenter {
        MeetingRecorderCenter(
            pendingStore: store ?? pendingStore,
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: try defaults ?? isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
    }

    /// An older recording's audio, written before this launch began.
    private func oldAudio(_ name: String) throws -> URL {
        let url = recordingsDir.appendingPathComponent(name)
        try Data([0x00]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                              ofItemAtPath: url.path)
        return url
    }

    func testAudioDismissedOnTheOldBuildNeverComesBack() async throws {
        let dismissed = try oldAudio("rec_20260801_090000.caf")
        let defaults = try isolatedDefaults()
        let first = try center(defaults: defaults)
        await first.restorePendingOnLaunch()
        XCTAssertEqual(first.recoverable, [], "no .meta on the old build: not pending")
        XCTAssertEqual(pendingRow(dismissed)?.dismissed, true)
        XCTAssertTrue(defaults.bool(forKey: MeetingRecorderCenter.legacyAudioTombstonedKey))

        let again = try center(defaults: defaults)
        await again.restorePendingOnLaunch()
        XCTAssertEqual(again.recoverable, [])
    }

    func testAudioWithItsMetaStaysPending() async throws {
        let pending = try oldAudio("rec_20260801_100000.caf")
        try #"{"eventID":"evt-1","title":"Standup"}"#.write(to: metaSidecar(pending), atomically: true, encoding: .utf8)
        let center = try center()
        await center.restorePendingOnLaunch()
        XCTAssertEqual(center.recoverable.map(\.audioURL), [pending])
        XCTAssertEqual(center.recoverable.first?.eventID, "evt-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaSidecar(pending).path))
    }

    func testTxtAndJSONWithoutMetaAreNotPending() async throws {
        let audio = try oldAudio("rec_20260801_110000.caf")
        try "kept".write(to: audio.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        try #"{"durationSec":1,"langStats":{}}"#
            .write(to: audio.deletingPathExtension().appendingPathExtension("json"), atomically: true, encoding: .utf8)
        let center = try center()
        await center.restorePendingOnLaunch()
        XCTAssertEqual(center.recoverable, [])
        XCTAssertEqual(pendingRow(audio)?.dismissed, true)
        XCTAssertNil(pendingRow(audio)?.transcript)
    }

    func testASavedRecordingGetsNoTombstoneAndIsNotOffered() async throws {
        let saved = try oldAudio("rec_20260801_120000.caf")
        try await pendingDB.write { try TestDatabase.insertMeetingTranscript($0, audioPath: saved.path) }
        let center = try center()
        await center.restorePendingOnLaunch()
        XCTAssertEqual(center.recoverable, [])
        XCTAssertNil(pendingRow(saved), "a saved recording needs no tombstone")
    }

    /// Audio this launch is writing (a recording started before the pool
    /// opened) is not taken for an older build's.
    func testAudioModifiedAfterLaunchIsNotTombstoned() async throws {
        let center = try center()
        let fresh = recordingsDir.appendingPathComponent("rec_20260801_130000.caf")
        try Data([0x00]).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: fresh.path)
        await center.restorePendingOnLaunch()
        XCTAssertEqual(center.recoverable.map(\.audioURL), [fresh])
        XCTAssertNil(pendingRow(fresh))
    }

    /// The pass fails on launch 1 (no database for it); a recording made in
    /// launch 1 whose row never landed is still this version's at launch 2:
    /// the cutoff stamped on launch 1 keeps it recoverable.
    func testARecordingOfALaunchWhosePassFailedIsNotTombstoned() async throws {
        let defaults = try isolatedDefaults()
        let launch1 = Date().addingTimeInterval(-600)
        let launch1Clock = { launch1 }
        _ = MeetingRecorderCenter(
            pendingStore: FailingPendingStore(),
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir,
            now: launch1Clock
        )
        let legacy = try oldAudio("rec_20260801_080000.caf") // an hour old: before launch 1
        let madeInLaunch1 = recordingsDir.appendingPathComponent("rec_20260801_085500.caf")
        try Data([0x00]).write(to: madeInLaunch1)
        try FileManager.default.setAttributes([.modificationDate: launch1.addingTimeInterval(60)],
                                              ofItemAtPath: madeInLaunch1.path)
        XCTAssertFalse(defaults.bool(forKey: MeetingRecorderCenter.legacyAudioTombstonedKey))

        let launch2 = try center(defaults: defaults)
        await launch2.restorePendingOnLaunch()
        XCTAssertEqual(launch2.recoverable.map(\.audioURL), [madeInLaunch1])
        XCTAssertEqual(pendingRow(legacy)?.dismissed, true)
        XCTAssertTrue(defaults.bool(forKey: MeetingRecorderCenter.legacyAudioTombstonedKey))
    }

    /// A failed `removePending` after a save must not bring the recording back.
    func testARowOfASavedRecordingIsNotOffered() async throws {
        let saved = try oldAudio("rec_20260801_140000.caf")
        try await pendingStore.begin(recording: saved.lastPathComponent, eventID: nil, title: "Saved", at: Date())
        try await pendingDB.write { try TestDatabase.insertMeetingTranscript($0, audioPath: saved.path) }
        let center = try center()
        await center.restorePendingOnLaunch()
        XCTAssertEqual(center.recoverable, [])
    }

    func testLaunchPrunesRowsWhoseAudioIsGone() async throws {
        let old = Date().addingTimeInterval(-86_400)
        try await pendingStore.begin(recording: "rec_20260801_150000.caf", eventID: nil, title: "Gone", at: old)
        try await pendingStore.dismiss(recording: "rec_20260801_160000.caf", at: old)
        let kept = try oldAudio("rec_20260801_170000.caf")
        try await pendingStore.begin(recording: kept.lastPathComponent, eventID: nil, title: "Kept", at: old)
        let center = try center()
        await center.restorePendingOnLaunch()
        XCTAssertEqual(try pendingStore.pending().map(\.recording), [kept.lastPathComponent])
        XCTAssertEqual(center.recoverable.map(\.audioURL), [kept])
    }

    /// The recorder starts first; the pending row follows once the capture
    /// shows, so a slow store never delays it and a failing one never stops it.
    func testASlowStoreNeverDelaysTheCapture() async throws {
        let store = GatedPendingStore(base: pendingStore)
        let center = try center(store: store)
        var config = singleWindowConfig()
        config.liveTranscription = false
        let start = Task { await center.startRecording(eventID: nil, title: "Slow", config: config) }
        let recording = await waitUntil("the capture to show") {
            if case .recording = center.captureState { return true }
            return false
        }
        XCTAssertTrue(recording)
        XCTAssertEqual(try pendingStore.pending(), [], "the row has not landed yet")
        store.release()
        await start.value
        XCTAssertEqual(try pendingStore.pending().count, 1)
    }

    /// MEETPRIV: a lock flipped while the row is still being written is
    /// re-applied once it lands, so a crash recovers the owner's choice.
    func testMeetPriv01_ALockFlippedBeforeTheRowLandsReachesTheRow() async throws {
        let store = GatedPendingStore(base: pendingStore)
        let center = try center(store: store)
        var config = singleWindowConfig()
        config.liveTranscription = false
        let start = Task { await center.startRecording(eventID: nil, title: "Slow", config: config) }
        let recording = await waitUntil("the capture to show") {
            if case .recording = center.captureState { return true }
            return false
        }
        XCTAssertTrue(recording)
        await center.setCapturePrivate(true)
        store.release()
        await start.value

        XCTAssertEqual(try pendingStore.pending().map(\.isPrivate), [true])
    }

    func testAFailingStoreNeverStopsTheCapture() async throws {
        let center = try center(store: FailingPendingStore())
        var config = singleWindowConfig()
        config.liveTranscription = false
        await center.startRecording(eventID: nil, title: "No row", config: config)
        guard case .recording = center.captureState else { return XCTFail("expected recording, got \(center.captureState)") }
        XCTAssertNil(center.captureError)
    }
}

/// Holds `begin` until released.
private final class GatedPendingStore: PendingTranscriptStore, @unchecked Sendable {
    private let base: PendingTranscriptStore
    private let gate = AsyncStream<Void>.makeStream()

    init(base: PendingTranscriptStore) { self.base = base }

    func release() { gate.continuation.finish() }

    func begin(recording: String, eventID: String?, title: String?, isPrivate: Bool, at: Date) async throws {
        for await _ in gate.stream {}
        try await base.begin(recording: recording, eventID: eventID, title: title, isPrivate: isPrivate, at: at)
    }
    func reserve(recording: String, eventID: String?, title: String?, isPrivate: Bool, at: Date) async throws -> Bool {
        try await base.reserve(recording: recording, eventID: eventID, title: title, isPrivate: isPrivate, at: at)
    }
    func setPrivate(recording: String, _ isPrivate: Bool) async throws {
        try await base.setPrivate(recording: recording, isPrivate)
    }
    func saveTranscript(recording: String, text: String, metaJSON: String, at: Date) async throws {
        try await base.saveTranscript(recording: recording, text: text, metaJSON: metaJSON, at: at)
    }
    func clearTranscript(recording: String) async throws { try await base.clearTranscript(recording: recording) }
    func dismiss(recording: String, at: Date) async throws { try await base.dismiss(recording: recording, at: at) }
    func pending() throws -> [PendingTranscript] { try base.pending() }
    func transcript(recording: String) throws -> PendingTranscript? { try base.transcript(recording: recording) }
    func remove(recording: String) async throws { try await base.remove(recording: recording) }
    func savedAudioPaths() throws -> Set<String> { try base.savedAudioPaths() }
}

/// Every write fails; reads see nothing.
private struct FailingPendingStore: PendingTranscriptStore {
    struct Failure: Error {}
    func begin(recording: String, eventID: String?, title: String?, isPrivate: Bool, at: Date) async throws { throw Failure() }
    func reserve(recording: String, eventID: String?, title: String?, isPrivate: Bool, at: Date) async throws -> Bool {
        throw Failure()
    }
    func setPrivate(recording: String, _ isPrivate: Bool) async throws { throw Failure() }
    func saveTranscript(recording: String, text: String, metaJSON: String, at: Date) async throws { throw Failure() }
    func clearTranscript(recording: String) async throws { throw Failure() }
    func dismiss(recording: String, at: Date) async throws { throw Failure() }
    func pending() throws -> [PendingTranscript] { [] }
    func transcript(recording: String) throws -> PendingTranscript? { nil }
    func remove(recording: String) async throws { throw Failure() }
    func savedAudioPaths() throws -> Set<String> { [] }
}
