import AppKit
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
private final class AwayInputs {
    var locked = false
    var asleep = false
    var idle: TimeInterval = 0
    var active = true

    var inputs: OwnerAwayCenter.Inputs {
        .init(
            screenLocked: { [weak self] in self?.locked ?? false },
            displaysAsleep: { [weak self] in self?.asleep ?? false },
            idleSeconds: { [weak self] in self?.idle ?? 0 },
            sessionActive: { [weak self] in self?.active ?? true }
        )
    }
}

@MainActor
final class OwnerAwayCenterTests: XCTestCase {
    private var notifications: NotificationCenter!
    private var fake: AwayInputs!
    private var box: OwnerAwayBox!
    private var center: OwnerAwayCenter!
    private var changes: [Bool] = []
    private var timers: [(due: TimeInterval, fire: @MainActor () -> Void)] = []
    private var now: TimeInterval = 0

    override func setUp() async throws {
        notifications = NotificationCenter()
        fake = AwayInputs()
        box = OwnerAwayBox()
        changes = []
        timers = []
        now = 0
        let sources = OwnerPresenceCenter.NotificationSources(
            app: notifications, workspace: notifications, distributed: notifications
        )
        let schedule: OwnerAwayCenter.Schedule = { [weak self] in self?.schedule($0, $1) ?? {} }
        center = OwnerAwayCenter(box: box, inputs: fake.inputs, sources: sources, schedule: schedule)
        center.onChange = { [weak self] in self?.changes.append($0) }
    }

    override func tearDown() async throws {
        center?.stop()
        center = nil
    }

    private func schedule(_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        let due = now + seconds
        timers.append((due, fire))
        return { [weak self] in self?.timers.removeAll { $0.due == due } }
    }

    private func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = timers.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
            timers.removeAll { $0.due == next.due }
            now = next.due
            next.fire()
        }
        now = end
    }

    func testLockNotificationTurnsAwayAtOnce() {
        center.start()
        fake.locked = true
        notifications.post(name: OwnerPresenceCenter.screenLockedNotification, object: nil)
        XCTAssertTrue(center.isAway)
        XCTAssertEqual(changes, [true])
    }

    func testUnlockReturnsAtOnce() {
        fake.locked = true
        center.start()
        XCTAssertTrue(center.isAway)
        fake.locked = false
        notifications.post(name: OwnerPresenceCenter.screenUnlockedNotification, object: nil)
        XCTAssertFalse(center.isAway)
    }

    func testLockNotificationWinsOverLaggingLiveRead() {
        center.start()
        notifications.post(name: OwnerPresenceCenter.screenLockedNotification, object: nil)
        XCTAssertTrue(center.isAway, "live read still says unlocked")
        fake.locked = true
        notifications.post(name: OwnerPresenceCenter.screenUnlockedNotification, object: nil)
        XCTAssertFalse(center.isAway, "live read still says locked")
        advance(15)
        XCTAssertTrue(center.isAway, "the poll re-reads the live value")
    }

    func testIdlePollTurnsAwayAfterThreshold() {
        center.start()
        fake.idle = 179
        advance(15)
        XCTAssertFalse(center.isAway)
        fake.idle = 180
        advance(15)
        XCTAssertTrue(center.isAway)
        fake.idle = 0
        advance(15)
        XCTAssertFalse(center.isAway)
    }

    func testOnChangeFiresOnlyOnChange() {
        center.start()
        advance(45)
        XCTAssertEqual(changes, [])
        fake.asleep = true
        notifications.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        notifications.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        advance(15)
        XCTAssertEqual(changes, [true])
    }

    func testBoxMirrorsState() {
        var seenInBox: [Bool] = []
        let box: OwnerAwayBox = box
        center.onChange = { _ in seenInBox.append(box.read()) }
        XCTAssertFalse(box.read())
        center.start()
        fake.active = false
        notifications.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertTrue(box.read())
        fake.active = true
        notifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertFalse(box.read())
        XCTAssertEqual(seenInBox, [true, false])
    }

    func testStopFreezesTimersAndObservers() {
        center.start()
        center.stop()
        fake.locked = true
        notifications.post(name: OwnerPresenceCenter.screenLockedNotification, object: nil)
        advance(30)
        XCTAssertFalse(center.isAway)
        XCTAssertTrue(timers.isEmpty)
    }
}
