import AppKit
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Which workbench session the owner is in, and since when they are away
/// from the others (spec 2026-10-10-owner-asks-v2 Part 2). The inputs of
/// Part 2.1 — app active, what the key window shows, screen lock, display
/// sleep — go through the pure `OwnerPresencePolicy`; none of them needs a
/// permission. The result is written to the `owner_presence` singleton for
/// Go's Stop guard (Part 2.3) and kept in memory for the escalation runner
/// (Part 5.2).
///
/// Entering a session is written at once and again every 30 s while in it
/// (the heartbeat Go trusts for 90 s), so a failed enter is recovered by the
/// next heartbeat. A loss is written only once it has lasted 2 s — a menu,
/// a sheet or a space switch animation is not leaving — except a screen
/// lock or display sleep, which clears at once, as quitting does. A failed
/// write is logged once per streak and retried at the next heartbeat; the
/// writes run on a serial queue and never block the UI. Owned by
/// `AppState`; every bookkeeping entry is in memory only.
@MainActor
@Observable
final class OwnerPresenceCenter {
    nonisolated static let heartbeatInterval: TimeInterval = 30
    /// A loss shorter than this is never written (Part 2.1 flicker debounce).
    nonisolated static let flickerDebounce: TimeInterval = 2
    nonisolated static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    nonisolated static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    /// What the key window shows: the workbench page with its selected
    /// session's pane (and whether the ask drawer is open beside it), or
    /// anything else.
    struct Screen: Equatable {
        var keyWindowShows: OwnerPresencePolicy.KeyWindow
        var selectedSession: Int64?

        static let other = Self(keyWindowShows: .other, selectedSession: nil)
    }

    /// Where the inputs' notifications come from; a test passes plain
    /// centers and posts to them.
    struct NotificationSources {
        /// `NSApplication` activation and `NSWindow` key changes.
        var app: NotificationCenter
        /// `NSWorkspace` display sleep and wake.
        var workspace: NotificationCenter
        /// The screen lock and unlock distributed notifications.
        var distributed: NotificationCenter

        static var live: Self {
            Self(
                app: .default,
                workspace: NSWorkspace.shared.notificationCenter,
                distributed: DistributedNotificationCenter.default()
            )
        }
    }

    /// One `owner_presence` upsert: the session, or nil for none.
    typealias Writer = @Sendable (_ sessionID: Int64?, _ at: Date) throws -> Void
    /// Runs `fire` once after `seconds` on the main actor; the returned
    /// closure cancels it. Seamed so a test moves time by hand.
    typealias Schedule = @MainActor (_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void

    /// The session the owner is in, after the 2 s debounce of a loss; nil
    /// when in none.
    private(set) var presentSessionID: Int64?
    /// Whether presence has been computed once since `start()`. Before that
    /// nothing is known: an unknown presence must not read as away.
    private(set) var hasSettled = false

    /// Every change of `presentSessionID`, and the first computation. One
    /// subscriber.
    @ObservationIgnored var onChange: (() -> Void)?
    /// What the key window shows now. Read under observation tracking, so a
    /// change of the observable state it reads is evaluated again; key
    /// window changes come through the notifications. Contract: the
    /// observable state it reads must not depend on those non-observable
    /// inputs (read it all, then gate on the key window), because one
    /// tracker is armed at a time and only an observable change re-arms it.
    @ObservationIgnored var screen: () -> Screen = { .other }
    /// The app's activation when `start()` runs; notifications follow it.
    @ObservationIgnored var isAppActive: () -> Bool = { NSApp?.isActive ?? false }
    /// Whether the screen is locked when `start()` runs (an app launched
    /// under a locked screen gets no lock notification); notifications
    /// follow it.
    @ObservationIgnored var isScreenLocked: () -> Bool = OwnerPresenceCenter.sessionScreenIsLocked

    @ObservationIgnored private let writer: Writer
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let schedule: Schedule
    @ObservationIgnored private let sources: NotificationSources
    /// One queue for every center of the process (a re-initialisation
    /// replaces the center): FIFO, so an enter and the leave after it land
    /// in that order, and the quit's clear lands after every write queued
    /// before it.
    nonisolated private static let writes = DispatchQueue(label: "watchtower.owner-presence.writes")
    /// How long quitting waits for the clear. A missed clear is covered by
    /// Go's 90 s staleness, so a hung database never holds the quit.
    nonisolated static let quitWait: TimeInterval = 1

    @ObservationIgnored private var appActive = false
    @ObservationIgnored private var screenLocked = false
    @ObservationIgnored private var displaysAsleep = false
    /// When the owner left each session they were in since launch.
    @ObservationIgnored private var awayStarts: [Int64: Date] = [:]
    /// The timer's cancel of a loss not yet 2 s old.
    @ObservationIgnored private var cancelPendingLoss: (() -> Void)?
    @ObservationIgnored private var cancelHeartbeat: (() -> Void)?
    /// The last completed write failed: the heartbeat retries it.
    @ObservationIgnored private var writeFailing = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var following = false
    /// One observation tracker is armed at a time; its change disarms it
    /// and the evaluation it triggers arms the next.
    @ObservationIgnored private var trackingArmed = false
    /// A tracker armed before `stop()` evaluates nothing when it fires.
    @ObservationIgnored private var trackingGeneration = 0

    init(
        writer: @escaping Writer,
        clock: @escaping () -> Date = { Date() },
        schedule: Schedule? = nil,
        sources: NotificationSources = .live
    ) {
        self.writer = writer
        self.clock = clock
        self.schedule = schedule ?? Self.liveSchedule
        self.sources = sources
    }

    /// The production writer: one upsert on `dbPool`.
    nonisolated static func databaseWriter(_ dbPool: DatabasePool) -> Writer {
        { sessionID, at in
            try dbPool.write { try OwnerPresenceQueries.upsert($0, sessionID: sessionID, at: at) }
        }
    }

    /// A one-shot `Timer` in the common modes, so it fires during menu
    /// tracking and a live resize too.
    static let liveSchedule: Schedule = { seconds, fire in
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    /// The production lock reading: the login session's dictionary
    /// (CoreGraphics, no permission involved). Absent means unlocked.
    nonisolated static func sessionScreenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Since when the owner is away from `sessionID`; nil while they are in
    /// it. Away starts when the loss is written — after the 2 s debounce,
    /// or at once on a lock, display sleep or another session's pane (spec
    /// Part 5.2): a question Go recorded inside the debounce saw the owner
    /// present, so it waits out the leave grace rather than escalating at
    /// once. A session the owner has not been in since launch reads as away
    /// since `.distantPast` — before any question it records, so such a
    /// question escalates at once (`away`, E10b), and never inside the 90 s
    /// leave grace.
    func awaySince(sessionID: Int64) -> Date? {
        guard presentSessionID != sessionID else { return nil }
        return awayStarts[sessionID] ?? .distantPast
    }

    /// Follows the inputs from now on and computes presence once; that first
    /// result is written whatever it is (so a row a crashed run, or a
    /// `stop()`, left behind is overwritten) and starts the heartbeat when
    /// in a session.
    func start() {
        guard !following else { return }
        following = true
        hasSettled = false
        appActive = isAppActive()
        screenLocked = isScreenLocked()
        displaysAsleep = false
        observeNotifications()
        evaluate()
    }

    /// Stops following: no timer is left and nothing new is written; a
    /// write already queued still lands. The row keeps its last write,
    /// which Go stops trusting after 90 s.
    func stop() {
        following = false
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        dropPendingLoss()
        cancelHeartbeat?()
        cancelHeartbeat = nil
        trackingArmed = false
        trackingGeneration += 1
    }

    /// The app quits (`applicationWillTerminate`): stops, and clears the row
    /// after every write queued earlier, waiting at most `quitWait` for it.
    func clearForQuit() {
        stop()
        presentSessionID = nil
        let writer = writer
        let now = clock()
        let done = DispatchSemaphore(value: 0)
        Self.writes.async {
            do {
                try writer(nil, now)
            } catch {
                // A failed clear, like a crash, is covered by Go's 90 s staleness.
                print("[OwnerPresence] clearing presence on quit failed: \(error.localizedDescription)")
            }
            done.signal()
        }
        if done.wait(timeout: .now() + Self.quitWait) == .timedOut {
            print("[OwnerPresence] clearing presence on quit timed out; Go reads the row as stale after 90 s")
        }
    }

    /// Computes presence again now (the inputs changed in a way no
    /// notification or observation reports).
    func refresh() {
        evaluate()
    }

    // MARK: - Inputs

    private func observeNotifications() {
        observe(sources.app, NSApplication.didBecomeActiveNotification) { $0.appActive = true }
        observe(sources.app, NSApplication.didResignActiveNotification) { $0.appActive = false }
        observe(sources.app, NSWindow.didBecomeKeyNotification) { _ in }
        observe(sources.app, NSWindow.didResignKeyNotification) { _ in }
        observe(sources.workspace, NSWorkspace.screensDidSleepNotification, clearsAtOnce: true) { $0.displaysAsleep = true }
        observe(sources.workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        observe(sources.distributed, Self.screenLockedNotification, clearsAtOnce: true) { $0.screenLocked = true }
        observe(sources.distributed, Self.screenUnlockedNotification) { $0.screenLocked = false }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        clearsAtOnce: Bool = false,
        update: @escaping @MainActor (OwnerPresenceCenter) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                self.evaluate(clearsAtOnce: clearsAtOnce)
            }
        }
        observers.append((center, token))
    }

    // MARK: - Presence

    /// The policy's session now. Arms the observation tracker when none is
    /// outstanding, so the next change of what the screen provider reads
    /// evaluates again.
    private func currentSession() -> Int64? {
        let shown = trackingArmed ? screen() : trackedScreen()
        return OwnerPresencePolicy.presentSession(
            appActive: appActive, keyWindowShows: shown.keyWindowShows, selectedSession: shown.selectedSession,
            screenLocked: screenLocked, displaysAsleep: displaysAsleep
        )
    }

    private func trackedScreen() -> Screen {
        trackingArmed = true
        let generation = trackingGeneration
        return withObservationTracking {
            screen()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.trackingGeneration == generation else { return }
                self.trackingArmed = false
                self.evaluate()
            }
        }
    }

    private func evaluate(clearsAtOnce: Bool = false) {
        guard following else { return }
        let session = currentSession()
        guard hasSettled else { return settle(session) }
        if session == presentSessionID {
            dropPendingLoss()
        } else if let session {
            enter(session)
        } else if clearsAtOnce {
            leave()
        } else if cancelPendingLoss == nil {
            cancelPendingLoss = schedule(Self.flickerDebounce) { [weak self] in self?.lossLasted() }
        }
    }

    /// The first computation: written whatever it is.
    private func settle(_ session: Int64?) {
        presentSessionID = session
        hasSettled = true
        write(session)
        if session != nil { restartHeartbeat() }
        onChange?()
    }

    /// The loss lasted the debounce: written, unless the owner is back.
    private func lossLasted() {
        guard following, cancelPendingLoss != nil else { return }
        cancelPendingLoss = nil
        let session = currentSession()
        guard session != presentSessionID else { return }
        if let session { enter(session) } else { leave() }
    }

    /// Gaining a session is written at once; the session left behind, if
    /// any, is away from now, when the switch is written.
    private func enter(_ session: Int64) {
        if let previous = presentSessionID { awayStarts[previous] = clock() }
        dropPendingLoss()
        awayStarts[session] = nil
        presentSessionID = session
        write(session)
        restartHeartbeat()
        onChange?()
    }

    /// The loss is written now, so the owner is away from now.
    private func leave() {
        dropPendingLoss()
        guard let previous = presentSessionID else { return }
        awayStarts[previous] = clock()
        presentSessionID = nil
        cancelHeartbeat?()
        cancelHeartbeat = nil
        write(nil)
        onChange?()
    }

    private func dropPendingLoss() {
        cancelPendingLoss?()
        cancelPendingLoss = nil
    }

    // MARK: - Writes

    private func restartHeartbeat() {
        cancelHeartbeat?()
        cancelHeartbeat = nil
        scheduleHeartbeat()
    }

    private func scheduleHeartbeat() {
        guard following, cancelHeartbeat == nil else { return }
        cancelHeartbeat = schedule(Self.heartbeatInterval) { [weak self] in self?.heartbeat() }
    }

    /// Every 30 s while in a session; out of one, only to retry a failed
    /// write (a failed retry schedules the next).
    private func heartbeat() {
        cancelHeartbeat = nil
        guard following else { return }
        if presentSessionID != nil || writeFailing { write(presentSessionID) }
        if presentSessionID != nil { scheduleHeartbeat() }
    }

    private func write(_ session: Int64?) {
        let writer = writer
        let now = clock()
        Self.writes.async { [weak self] in
            let failure: Error?
            do {
                try writer(session, now)
                failure = nil
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.writeFinished(failure) }
            }
        }
    }

    private func writeFinished(_ failure: Error?) {
        guard let failure else {
            writeFailing = false
            return
        }
        if !writeFailing {
            print("[OwnerPresence] presence write failed, retrying at the next heartbeat: \(failure.localizedDescription)")
        }
        writeFailing = true
        scheduleHeartbeat()
    }

    /// Waits until every write queued so far has run and reported back (a
    /// test seam).
    func flushWrites() async {
        await withCheckedContinuation { continuation in
            Self.writes.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
