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

/// The keep-awake log: a refused assertion and an unreadable live-session count are logged, never swallowed.
let keepAwakeLogger = Logger(subsystem: Constants.bundleID, category: "KeepAwake")

/// Logs a refused assertion once per streak of refusals: the companion retries every 30 s.
final class IOKitPower: PowerAsserting {
    private var refusing = false

    func create(reason: String) -> UInt32? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id
        )
        guard result == kIOReturnSuccess else {
            if !refusing {
                keepAwakeLogger.error("keep-awake assertion refused: IOReturn \(result, privacy: .public)")
            }
            refusing = true
            return nil
        }
        refusing = false
        return id
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
    /// Written on the main actor only; read by `deinit` after every other
    /// reference is gone.
    nonisolated(unsafe) private var assertionID: UInt32?

    init(power: PowerAsserting = IOKitPower()) {
        self.power = power
    }

    /// An assertion still held when its owner goes away is released (a
    /// quit drops it with the process anyway).
    deinit {
        if let assertionID { power.release(assertionID) }
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
