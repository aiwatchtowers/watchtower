import Foundation

/// The seam between a session client and the `watchtower ai session`
/// process: the real one wraps `Process`, tests use `FakeChatSessionProcess`.
/// `events` yields `.exited` and then finishes when the process ends.
package protocol ChatSessionProcess: AnyObject, Sendable {
    var events: AsyncStream<ChatEvent> { get }
    func send(_ command: ChatCommand) throws
    /// SIGTERM, at most once per process: a second SIGTERM makes the Go side
    /// exit without its temp-file cleanup.
    func terminate()
    /// SIGKILL — the last resort after `terminate` went unanswered.
    func kill()
}
