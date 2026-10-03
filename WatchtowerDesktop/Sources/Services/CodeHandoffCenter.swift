import AppKit
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// A code question waiting in the hand-off sheet.
struct CodeHandoffRequest: Identifiable, Equatable {
    let id = UUID()
    let project: Workbench
    /// `HandoffText`: what the session receives.
    let text: String
}

/// Where the sheet sends a hand-off.
enum CodeHandoffTarget: Hashable {
    /// A running Claude Code session of the workbench.
    case session(Int64)
    case newSession
}

/// One running session the sheet offers.
struct CodeHandoffSessionChoice: Identifiable, Equatable {
    let session: TerminalSession
    let state: SessionSwitcherPresentation.State

    var id: Int64 { session.id }
    /// A Return would answer the permission prompt it shows.
    var isWaitingForApproval: Bool { state == .needsApproval }
}

/// "Hand to Claude Code" (⌥⌘↩, spec 2026-10-02 §9.5), on `AppState`: a code
/// question goes from the popover, the Questions tab or Open Quickly to a
/// workbench Claude Code session — "ask" answers in place, "delegate" goes
/// to Claude Code. A request opens the page's sheet; its Send is the
/// owner's confirmation. A running session gets the text pasted
/// (`TerminalCenter.submitPrompt`) and submitted only when it waits idle at
/// its prompt (ruling R52; else the owner presses Return), a new one starts with it as
/// its first prompt; either way the session opens beside the editor in a
/// split (`Placement.beside(.files)`: a split keeps the editor and swaps
/// the other pane, as `keeping` does; a single pane splits instead of
/// switching away from the editor).
@MainActor
@Observable
final class CodeHandoffCenter {
    /// Per workbench: the hand-off the sheet shows.
    private(set) var requests: [Int64: CodeHandoffRequest] = [:]
    /// Per workbench: why the last Send did not go (shown in the sheet).
    private(set) var errors: [Int64: String] = [:]
    @ObservationIgnored weak var workbenches: WorkbenchesViewModel?
    @ObservationIgnored weak var terminalCenter: TerminalCenter?
    @ObservationIgnored var dbPool: DatabasePool?
    @ObservationIgnored private let beep: @MainActor () -> Void
    @ObservationIgnored private let now: () -> Date

    init(beep: @escaping @MainActor () -> Void = { NSSound.beep() }, now: @escaping () -> Date = Date.init) {
        self.beep = beep
        self.now = now
    }

    // MARK: Requests

    /// The popover's or the Questions tab's conversation, from its stored
    /// messages (a reply still streaming is left out — `HandoffText`). No
    /// question yet, or a failed read, beeps.
    func handConversation(_ question: CodeQuestionRef) async {
        guard let dbPool else {
            beep()
            return
        }
        let messages: [ChatMessageRecord]
        do {
            messages = try await dbPool.read {
                try ChatMessageQueries.fetchByConversation($0, conversationID: question.conversationID)
            }
        } catch {
            NSLog("CodeHandoffCenter: reading conversation %lld: %@", question.conversationID, error.localizedDescription)
            beep()
            return
        }
        guard let text = HandoffText.conversation(origin: question.origin, messages: messages) else {
            beep()
            return
        }
        present(CodeHandoffRequest(project: question.project, text: text))
    }

    /// Open Quickly's ⌥⌘↩: the query, asked about `origin` (the open file).
    func handQuery(_ query: String, project: Workbench, origin: CodeQuestionOrigin) {
        guard let text = HandoffText.query(query, origin: origin) else {
            beep()
            return
        }
        present(CodeHandoffRequest(project: project, text: text))
    }

    func cancel(workbenchID: Int64) {
        requests[workbenchID] = nil
        errors[workbenchID] = nil
    }

    private func present(_ request: CodeHandoffRequest) {
        errors[request.project.id] = nil
        requests[request.project.id] = request
    }

    // MARK: The sheet

    /// The workbench's running Claude Code sessions, in the panel's order.
    func choices(workbenchID: Int64) -> [CodeHandoffSessionChoice] {
        guard let vm = workbenches, let live = terminalCenter?.liveIDs else { return [] }
        return vm.orderedSessions(projectID: workbenchID)
            .filter { $0.kind == .claude && live.contains($0.id) }
            .map { CodeHandoffSessionChoice(session: $0, state: vm.sessionState($0)) }
    }

    /// The session Send comments would use when it can take the text, else
    /// a new session.
    func defaultTarget(workbenchID: Int64) -> CodeHandoffTarget {
        let choices = choices(workbenchID: workbenchID)
        if let active = terminalCenter?.activeSession(projectID: workbenchID),
           let choice = choices.first(where: { $0.id == active.id }), !choice.isWaitingForApproval {
            return .session(active.id)
        }
        return .newSession
    }

    /// The sheet's Send. True when the hand-off went (the sheet closes);
    /// false keeps the sheet with `errors` saying why.
    @discardableResult
    func send(to target: CodeHandoffTarget, workbenchID: Int64) async -> Bool {
        guard let request = requests[workbenchID], let vm = workbenches else { return false }
        switch target {
        case let .session(id):
            // Re-checked at Send: the state may have changed while the sheet was open.
            guard let choice = choices(workbenchID: workbenchID).first(where: { $0.id == id }) else {
                errors[workbenchID] = "That session is no longer running. Pick another or start a new one."
                return false
            }
            guard !choice.isWaitingForApproval else {
                errors[workbenchID] = "That session is waiting for a permission answer. Answer it in the terminal first."
                return false
            }
            // Return only into a session idle at its prompt, re-read (a
            // fresh poll of the stored states) after the pause, and only while the sheet's request still stands (a
            // Cancel during the pause stops it) — ruling R52.
            let session = choice.session
            let canSubmit = { [weak self] in
                self?.requests[workbenchID]?.id == request.id && vm.sessionState(session) == .waitingForOwner
            }
            guard let center = terminalCenter,
                  await center.submitPrompt(request.text, sessionID: id, refresh: { await vm.agentStates?.poll() },
                                            submitIf: canSubmit) != .noSession else {
                errors[workbenchID] = "That session is no longer running. Pick another or start a new one."
                return false
            }
            guard requests[workbenchID]?.id == request.id else { return false }
            finish(request)
            await vm.open(session, placement: .beside(.files))
        case .newSession:
            finish(request)
            await vm.startNewSession(project: request.project, title: TerminalSessionNaming.provisional(now: now()),
                                     prompt: request.text, placement: .beside(.files))
        }
        return true
    }

    /// A newer request (another ⌥⌘↩ meanwhile) stays.
    private func finish(_ request: CodeHandoffRequest) {
        let workbenchID = request.project.id
        guard requests[workbenchID]?.id == request.id else { return }
        requests[workbenchID] = nil
        errors[workbenchID] = nil
    }
}
