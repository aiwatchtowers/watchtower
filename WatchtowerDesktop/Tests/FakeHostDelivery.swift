import Foundation
@testable import WatchtowerDesktop
import WatchtowerCore

/// A stand-in for the session host's `Deliver` (Go
/// `internal/sessionhost/deliver.go`) behind a test's fake process. The
/// host's algorithm — the prompt state, the pause, the run check, the
/// owner's keys — is pinned by its own Go tests (`TestProj12_*` in
/// `internal/sessionhost/deliver_test.go`); this replays only its visible
/// shape, so a Desktop test can see what the app asked (`lines`), how it
/// answered the re-check (`replies`) and what reached the "PTY" (`write`):
/// the paste, the pause, the re-check, then the Return only when the line
/// asked for one, the re-check is fresh, allows it and shows no dialog,
/// and no earlier line of this fake is left typed. A relaunch (`newRun`)
/// during the pause is no session.
@MainActor
final class FakeHostDelivery {
    private(set) var lines: [SessionDeliverLine] = []
    private(set) var replies: [DeliverCheckReply] = []
    /// The host's pause between the paste and the re-check.
    var pause: (_ settle: Duration?) async -> Void = { _ in }
    /// Whether the program enabled bracketed paste (2004).
    var bracketedPaste: () -> Bool = { true }
    /// The bytes the host writes to the PTY.
    var write: ([UInt8]) -> Void = { _ in }
    /// The host's delivery events to the attached pane.
    var event: (SessionHostDeliveryEvent) -> Void = { _ in }
    /// A line of this fake sits in the prompt without its Return.
    var leftTyped = false
    private var run = 0
    /// Lines in their pause, and whether another line reached the prompt
    /// meanwhile (the host's `text_during_pause`).
    private var pausing = 0
    private var textDuringPause = false

    /// A new process run: an empty prompt.
    func newRun() {
        run += 1
        leftTyped = false
    }

    func deliver(_ line: SessionDeliverLine, check: @escaping @MainActor () async -> DeliverCheckReply) async -> DeliverOutcome {
        lines.append(line)
        guard bracketedPaste() else { return .noPasteMode }
        // A line in its pause holds the prompt too (the host's pending Return).
        let besideText = leftTyped || pausing > 0
        if line.holdIfPromptText, besideText { return .held("prompt_has_text") }
        let started = run
        if case let .paste(bytes) = WorkbenchCommentPrompt.terminalPayload(
            line.text, bracketedPaste: true, keepingLineBreaks: line.keepLineBreaks,
            keepingFormatCharacters: line.keepFormat
        ) {
            write(bytes)
        }
        send(.pasted)
        guard line.submitIf, !besideText else {
            if pausing > 0 { textDuringPause = true }
            return leaveTyped(besideText: besideText)
        }
        pausing += 1
        textDuringPause = false
        await pause(line.settle)
        let reply = await check()
        pausing -= 1
        replies.append(reply)
        guard run == started else { return .noSession }
        guard reply.fresh, reply.canSubmit, !reply.answersDialog, !textDuringPause else {
            return leaveTyped(besideText: textDuringPause)
        }
        write([0x0D])
        send(.submitted)
        return .submitted
    }

    private func leaveTyped(besideText: Bool) -> DeliverOutcome {
        leftTyped = true
        send(.leftTyped, besideText: besideText)
        return .typed
    }

    private func send(_ kind: SessionHostDeliveryEvent.Kind, besideText: Bool = false) {
        event(SessionHostDeliveryEvent(row: 0, run: "", kind: kind, besideText: besideText))
    }
}
