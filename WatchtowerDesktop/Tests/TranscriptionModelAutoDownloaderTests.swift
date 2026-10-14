import Foundation
import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

/// A sleep the test ends by hand, so the wait loop runs without real time.
@MainActor
private final class ManualSleep {
    private var pending: [CheckedContinuation<Void, Never>] = []

    var waiting: Bool { !pending.isEmpty }

    func sleep() async {
        await withCheckedContinuation { pending.append($0) }
    }

    func wake() {
        let woken = pending
        pending = []
        woken.forEach { $0.resume() }
    }
}

/// The Meetings goal's download ahead of use as a sequence (#744): goals
/// changed later, a goal dropped while the download waits for the first
/// sync, one wait per trigger burst, the cap counted from the first trigger,
/// and a Settings value that names no model.
@MainActor
final class TranscriptionModelAutoDownloaderTests: XCTestCase {
    private let key = TranscriptionModelProvisioner.ModelKey(providerID: "whisperkit", model: "large-v3")
    private var goals: Set<OnboardingGoal> = []
    private var modelKey: TranscriptionModelProvisioner.ModelKey?
    private var synced = true
    private var clock = Date()
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        goals = []
        modelKey = key
        synced = true
        clock = Date()
        suiteName = "TranscriptionModelAutoDownloaderTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func make(
        _ download: HeldDownload,
        sleep: ManualSleep? = nil,
        downloadsModel: @escaping (TranscriptionModelProvisioner.ModelKey) -> Bool = { _ in true }
    ) -> (TranscriptionModelAutoDownloader, TranscriptionModelProvisioner) {
        let sleep = sleep ?? ManualSleep()
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let provisioner = TranscriptionModelProvisioner.forTests(download, defaults: defaults,
                                                                 downloadsModel: downloadsModel)
        let auto = TranscriptionModelAutoDownloader(
            inputs: .init(
                goals: { [weak self] in self?.goals ?? [] },
                onboardingComplete: { true },
                modelKey: { [weak self] in self?.modelKey },
                firstSyncFinished: { [weak self] in self?.synced ?? false }
            ),
            provisioner: provisioner,
            sleep: { _ in await sleep.sleep() },
            now: { [weak self] in self?.clock ?? Date() })
        return (auto, provisioner)
    }

    private func settle(_ auto: TranscriptionModelAutoDownloader) async {
        await auto.task?.value
    }

    /// Wall-clock patience, not a yield count: the download runs on a
    /// detached task that a loaded machine may schedule late.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testGoalsChangedLaterStartTheDownloadOnTheNextTrigger() async {
        let download = HeldDownload()
        let (auto, provisioner) = make(download)

        goals = [.development]
        auto.run()
        await settle(auto)
        XCTAssertEqual(download.calls, 0, "no Meetings goal: nothing downloads")
        XCTAssertNil(auto.task)

        goals = [.development, .meetings]   // a re-run added the goal
        auto.run()
        await waitUntil("the download to start") { download.isHeld }
        XCTAssertNotNil(provisioner.download(for: key))
        download.finish()
    }

    func testAGoalDroppedWhileWaitingForTheFirstSyncStopsIt() async {
        let download = HeldDownload()
        let sleep = ManualSleep()
        let (auto, _) = make(download, sleep: sleep)
        goals = [.meetings]
        synced = false

        auto.run()
        await waitUntil("the wait") { sleep.waiting }
        goals = [.development]
        sleep.wake()
        await settle(auto)

        XCTAssertEqual(download.calls, 0)
        XCTAssertNil(auto.task, "the next trigger asks afresh")
    }

    func testTheFirstSyncFinishingStartsTheDownload() async {
        let download = HeldDownload()
        let sleep = ManualSleep()
        let (auto, _) = make(download, sleep: sleep)
        goals = [.meetings]
        synced = false

        auto.run()
        await waitUntil("the wait") { sleep.waiting }
        XCTAssertEqual(download.calls, 0, "the first sync goes first")
        synced = true
        sleep.wake()
        await waitUntil("the download to start") { download.isHeld }
        download.finish()
    }

    /// A trigger while the download waits (Calendar opened) joins that wait,
    /// so the cap counts from the first trigger and never restarts.
    func testTriggersWhileWaitingJoinItAndTheCapCountsFromTheFirst() async {
        let download = HeldDownload()
        let sleep = ManualSleep()
        let (auto, _) = make(download, sleep: sleep)
        goals = [.meetings]
        synced = false

        auto.run()
        await waitUntil("the wait") { sleep.waiting }
        let first = auto.task
        clock = clock.addingTimeInterval(TranscriptionModelAutoDownload.firstSyncMaxWait - 60)
        auto.run()
        XCTAssertEqual(auto.task, first, "a second trigger joins the wait")

        sleep.wake()
        await waitUntil("the next wait") { sleep.waiting }
        XCTAssertEqual(download.calls, 0, "still inside the cap")

        clock = clock.addingTimeInterval(60)
        sleep.wake()
        await waitUntil("the capped download to start") { download.isHeld }
        download.finish()
    }

    /// A Settings value that names no model ends the ask without wedging:
    /// a later trigger with a real model still downloads.
    func testNoModelInSettingsDoesNotWedgeLaterTriggers() async {
        let download = HeldDownload()
        let (auto, _) = make(download)
        goals = [.meetings]
        modelKey = nil

        auto.run()
        await settle(auto)
        XCTAssertNil(auto.task)

        modelKey = key
        auto.run()
        await waitUntil("the download to start") { download.isHeld }
        download.finish()
    }

    /// An engine whose assets are macOS's (Apple) never makes a recording
    /// wait, but the Meetings goal still installs them once in the background.
    func testTheMeetingsGoalInstallsAnAppleEngineOnce() async {
        let download = HeldDownload()
        let notOurs: (TranscriptionModelProvisioner.ModelKey) -> Bool = { $0.providerID != "apple" }
        let (auto, provisioner) = make(download, downloadsModel: notOurs)
        let apple = TranscriptionModelProvisioner.ModelKey(providerID: "apple", model: "system")
        goals = [.meetings]
        modelKey = apple
        XCTAssertTrue(provisioner.isDownloaded(apple), "a recording never waits on it")

        auto.run()
        await waitUntil("the install to start") { download.isHeld }
        download.finish()
        await provisioner.task(for: apple)?.value
        XCTAssertTrue(provisioner.isConfirmedOnDisk(apple))

        auto.run()
        await settle(auto)
        XCTAssertEqual(download.calls, 1, "installed once")
    }
}
