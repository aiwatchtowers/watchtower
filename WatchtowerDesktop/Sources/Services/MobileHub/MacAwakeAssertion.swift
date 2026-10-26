import Foundation
import GRDB
import IOKit.pwr_mgt
import os
import WatchtowerCore

/// The power-assertion calls, behind a seam so tests never touch IOKit.
protocol PowerAsserting {
    /// A "prevent idle system sleep" assertion; nil when the system refused.
    func create(reason: String) -> UInt32?
    func release(_ id: UInt32)
}

struct IOKitPower: PowerAsserting {
    func create(reason: String) -> UInt32? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id
        )
        return result == kIOReturnSuccess ? id : nil
    }

    func release(_ id: UInt32) {
        IOPMAssertionRelease(IOPMAssertionID(id))
    }
}

/// Holds at most one "prevent idle system sleep" assertion: `update(hold:)`
/// creates it when asked to hold and none is held, releases it when not.
/// A refused create is tried again on the next update.
@MainActor
final class MacAwakeAssertion {
    static let reason = "Watchtower: a session is running and your iPhone is connected"

    private let power: PowerAsserting
    private var assertionID: UInt32?

    init(power: PowerAsserting = IOKitPower()) {
        self.power = power
    }

    var isHolding: Bool { assertionID != nil }

    func update(hold: Bool) {
        if hold {
            guard assertionID == nil else { return }
            assertionID = power.create(reason: Self.reason)
        } else if let id = assertionID {
            power.release(id)
            assertionID = nil
        }
    }
}

/// Evaluates `KeepAwakePolicy` every 30 s (the publisher's full-tick
/// cadence) while the hub runs, and drops the assertion when the hub stops
/// (a hub off or rebuilt; a quit ends the process, which drops it).
final class KeepAwakeCompanion: HubCompanion, @unchecked Sendable {
    static let interval: Duration = .seconds(30)

    private let assertion: MacAwakeAssertion
    private let enabled: @Sendable () -> Bool
    private let liveBoardSessions: @Sendable () -> Int
    private let lastPhoneContact: @Sendable () -> Date?
    private let now: @Sendable () -> Date
    private let loop = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    init(
        assertion: MacAwakeAssertion,
        enabled: @escaping @Sendable () -> Bool,
        liveBoardSessions: @escaping @Sendable () -> Int,
        lastPhoneContact: @escaping @Sendable () -> Date?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.assertion = assertion
        self.enabled = enabled
        self.liveBoardSessions = liveBoardSessions
        self.lastPhoneContact = lastPhoneContact
        self.now = now
    }

    /// Live board sessions: the workbenches with a live agent session (plain shells never count), by the
    /// slice's own query.
    static func liveBoardSessions(_ pool: DatabasePool, liveIDs: Set<Int64>) -> Int {
        guard !liveIDs.isEmpty else { return 0 }
        return (try? pool.read { try TerminalSessionSlice.liveWorkbenchIDs($0, liveIDs: liveIDs).count }) ?? 0
    }

    func evaluate() async {
        let hold = KeepAwakePolicy.shouldHold(
            enabled: enabled(), liveBoardSessions: liveBoardSessions(), lastPhoneContact: lastPhoneContact(), now: now()
        )
        await assertion.update(hold: hold)
    }

    func start() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.evaluate()
                try? await Task.sleep(for: Self.interval)
            }
        }
        loop.withLock { current in
            current?.cancel()
            current = task
        }
    }

    nonisolated func stop() {
        loop.withLock { current in
            current?.cancel()
            current = nil
        }
        // The hub stops on the main actor (`MobileHubService.stop`), so the release is immediate.
        MainActor.assumeIsolated { assertion.update(hold: false) }
    }
}
