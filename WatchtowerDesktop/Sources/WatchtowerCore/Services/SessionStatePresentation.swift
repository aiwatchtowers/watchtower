import Foundation

/// How a session's state is drawn (spec 2026-10-03-workbench-session-report
/// §4b): the dot's colour, the glyph beside it, fill or ring, and the
/// caption every site also sets as the accessibility label. Pure, so the
/// table is testable; the views map `Tone` to system colours.
package enum SessionStatePresentation {
    package typealias State = SessionSwitcherPresentation.State

    /// The dot's colour: system green, orange, blue, red, or `.secondary`.
    package enum Tone: Equatable, Sendable {
        case green, orange, blue, red, secondary
    }

    package static func color(for state: State) -> Tone {
        switch state.kind {
        case .working, .running, .background: .green
        case .waitingOnAsk, .needsApproval: .orange
        case .finished: state.openAsks > 0 ? .orange : .blue
        case .failed: .red
        case .stopped, .notStarted: .secondary
        }
    }

    /// The SF Symbol beside the dot; nil for none. A working or background
    /// session's `questionmark` comes with the open-ask count.
    package static func glyph(for state: State) -> String? {
        switch state.kind {
        case .working: state.openAsks > 0 ? "questionmark" : nil
        case .background: state.openAsks > 0 ? "questionmark" : "person.2.fill"
        case .waitingOnAsk: "questionmark"
        case .needsApproval: "hand.raised.fill"
        case .finished: "checkmark"
        case .stopped: "pause.fill"
        case .failed: "exclamationmark"
        case .running, .notStarted: nil
        }
    }

    /// A session that is not live draws a ring in its kind's colour.
    package static func isRing(_ state: State) -> Bool { !state.live }

    /// A live session whose background agents run pulses its dot.
    package static func pulses(_ state: State) -> Bool { state.live && state.kind == .background }

    /// The caption naming the state's own oldest open ask.
    package static func caption(for state: State) -> String {
        caption(for: state, oldestAskID: state.oldestAskID)
    }

    /// `oldestAskID` names the ask a waiting session points at ("ask #12");
    /// without it the caption reads "Waiting for you".
    package static func caption(for state: State, oldestAskID: Int64?) -> String {
        switch state.kind {
        case .working:
            state.openAsks > 0 ? "Working · \(asksOpen(state.openAsks))" : "Working"
        case .waitingOnAsk:
            "Waiting for you"
                + (oldestAskID.map { " · ask #\($0)" } ?? "")
                + (state.openAsks > 1 ? " · \(state.openAsks) asks" : "")
        case .needsApproval:
            "Needs approval"
        case .finished:
            state.openAsks > 0 ? "Finished · \(asksOpen(state.openAsks))" : "Finished"
        case .stopped:
            "Stopped"
        case .background:
            backgroundCaption(state)
        case .failed:
            errorCaption(state.error)
        case .running:
            "Running"
        case .notStarted:
            "Not running"
        }
    }

    /// `StopFailure`'s error type (`rate_limit`) read as words: "Error: rate
    /// limit"; none → "Stopped on an error".
    private static func errorCaption(_ error: String) -> String {
        let words = error.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? "Stopped on an error" : "Error: \(words)"
    }

    /// "Agents working" (no count shown), "1 agent working", "N agents
    /// working", with the open asks.
    private static func backgroundCaption(_ state: State) -> String {
        let agents = switch state.backgroundAgents {
        case ...0: "Agents working"
        case 1: "1 agent working"
        default: "\(state.backgroundAgents) agents working"
        }
        return state.openAsks > 0 ? "\(agents) · \(asksOpen(state.openAsks))" : agents
    }

    private static func asksOpen(_ count: Int) -> String {
        count == 1 ? "1 ask open" : "\(count) asks open"
    }
}
