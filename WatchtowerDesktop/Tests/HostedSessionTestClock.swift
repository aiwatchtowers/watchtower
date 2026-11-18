import Foundation
@testable import WatchtowerDesktop

/// A hosted session's clock and reconnect pauses for tests (#1086): a
/// pause is recorded and moves the clock on at once, so no test sleeps.
@MainActor
final class HostedSessionTestClock {
    private(set) var now = ContinuousClock.now
    /// The reconnect pauses taken, in order.
    private(set) var pauses: [Duration] = []

    func advance(by duration: Duration) {
        now += duration
    }

    func clearPauses() {
        pauses = []
    }

    /// Drives `session`'s clock and reconnect pauses; its other waits
    /// (`sleep`) only yield.
    func drive(_ session: HostedTerminalSession) {
        session.now = { self.now }
        session.reconnectSleep = { pause in
            self.pauses.append(pause)
            self.now += pause
        }
        session.sleep = { _ in await Task.yield() }
    }
}

extension HostedTerminalSession {
    /// Waits out a recovery or a settle: each look-up and the connection it
    /// opens, until no new one follows.
    func settled() async {
        var seen: Task<Void, Never>?
        while let task = recovering, task != seen {
            seen = task
            await task.value
            await connecting?.value
        }
        await connecting?.value
        await settling?.value
    }
}
