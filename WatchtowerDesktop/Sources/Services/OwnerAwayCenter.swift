import AppKit
import CoreGraphics
import Foundation
import Observation
import WatchtowerCore

/// A lock-protected flag the mobile hub reads off the main actor.
final class OwnerAwayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var away = false

    func read() -> Bool { lock.withLock { away } }
    func write(_ value: Bool) { lock.withLock { away = value } }
}

/// Follows whether the owner is away from the Mac (`OwnerAwayPolicy`) and
/// mirrors it into an `OwnerAwayBox` for the phone alert gate. Re-evaluates
/// on the lock/unlock, display sleep/wake and session active/resign
/// notifications (so lock and return are seen at once) and on a 15 s timer
/// (idleness raises no notification). None of the inputs needs a permission.
/// The box is written before `onChange` fires. Owned by `AppState`, one per
/// app (`AppState.ownerAwayCenter`, never rebuilt).
@MainActor
@Observable
final class OwnerAwayCenter {
    nonisolated static let pollInterval: TimeInterval = 15

    struct Inputs {
        var screenLocked: () -> Bool
        var displaysAsleep: () -> Bool
        var idleSeconds: () -> TimeInterval
        var sessionActive: () -> Bool

        static let live = Self(
            screenLocked: OwnerPresenceCenter.sessionScreenIsLocked,
            displaysAsleep: { CGDisplayIsAsleep(CGMainDisplayID()) != 0 },
            idleSeconds: {
                // kCGAnyInputEventType (~0): any keyboard, mouse or tablet event.
                guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
                return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            },
            sessionActive: {
                guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
                return (session["kCGSSessionOnConsoleKey"] as? Bool) ?? true
            }
        )
    }

    /// Runs `fire` once after `seconds` on the main actor; the returned
    /// closure cancels it. Seamed so a test moves time by hand.
    typealias Schedule = OwnerPresenceCenter.Schedule

    private(set) var isAway = false
    @ObservationIgnored var onChange: ((Bool) -> Void)?

    /// The mirror the mobile hub reads; one per app, so the hub captures it once.
    @ObservationIgnored let box: OwnerAwayBox
    @ObservationIgnored private let inputs: Inputs
    @ObservationIgnored private let sources: OwnerPresenceCenter.NotificationSources
    @ObservationIgnored private let schedule: Schedule
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var cancelPoll: (() -> Void)?
    @ObservationIgnored private var following = false
    /// Set by the lock notifications, refreshed from the live read at start and each poll.
    @ObservationIgnored private var screenLocked = false

    init(
        box: OwnerAwayBox,
        inputs: Inputs = .live,
        sources: OwnerPresenceCenter.NotificationSources = .live,
        schedule: Schedule? = nil
    ) {
        self.box = box
        self.inputs = inputs
        self.sources = sources
        self.schedule = schedule ?? OwnerPresenceCenter.liveSchedule
    }

    /// Follows the inputs from now on; computes once and writes the box.
    func start() {
        guard !following else { return }
        following = true
        screenLocked = inputs.screenLocked()
        observe(sources.distributed, OwnerPresenceCenter.screenLockedNotification) { $0.screenLocked = true }
        observe(sources.distributed, OwnerPresenceCenter.screenUnlockedNotification) { $0.screenLocked = false }
        observe(sources.workspace, NSWorkspace.screensDidSleepNotification) { _ in }
        observe(sources.workspace, NSWorkspace.screensDidWakeNotification) { _ in }
        observe(sources.workspace, NSWorkspace.sessionDidBecomeActiveNotification) { _ in }
        observe(sources.workspace, NSWorkspace.sessionDidResignActiveNotification) { _ in }
        evaluate()
        scheduleNextPoll()
    }

    /// The lock notification is trusted over the live read, which can lag it;
    /// the poll re-reads the live value.
    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        update: @escaping @MainActor (OwnerAwayCenter) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                self.evaluate()
            }
        }
        observers.append((center, token))
    }

    /// Stops following; the box keeps its last value.
    func stop() {
        following = false
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        cancelPoll?()
        cancelPoll = nil
    }

    private func scheduleNextPoll() {
        guard following else { return }
        cancelPoll = schedule(Self.pollInterval) { [weak self] in
            guard let self, self.following else { return }
            self.screenLocked = self.inputs.screenLocked()
            self.evaluate()
            self.scheduleNextPoll()
        }
    }

    private func evaluate() {
        guard following else { return }
        let away = OwnerAwayPolicy.isAway(
            screenLocked: screenLocked, displaysAsleep: inputs.displaysAsleep(),
            idleSeconds: inputs.idleSeconds(), sessionActive: inputs.sessionActive()
        )
        guard away != isAway else {
            box.write(away)
            return
        }
        isAway = away
        box.write(away)
        onChange?(away)
    }
}

extension AppState {
    /// Whether the owner is away from the Mac (phone alert gate, spec
    /// 2026-10-25 §5.1).
    var ownerAwayBox: OwnerAwayBox { ownerAwayCenter.box }
}
