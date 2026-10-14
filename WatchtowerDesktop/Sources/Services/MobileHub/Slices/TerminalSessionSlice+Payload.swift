import Foundation
import WatchtowerCore

extension TerminalSessionSlice {
    func makePayload(_ item: Published, closedAsks: Int) -> Payload {
        let session = item.session
        let state = item.state
        let record = kind.recordName(id: String(session.id))
        let title = SliceClip.text(session.title, limit: 200)
        let caption = SliceClip.text(SessionStatePresentation.caption(for: state), limit: 120)
        let finish = SliceClip.text(item.row?.finishSummary ?? "", limit: 2000)
        let error = SliceClip.text(state.error, limit: 60)
        let summary = reportSummary(item.workbenchID, session.id)
        let prLine = summary.map { SliceClip.text($0.prLine, limit: 120) }
        return Payload(
            id: session.id,
            workbenchID: item.workbenchID,
            title: title.text, titleClipped: title.clipped,
            targetID: session.targetID,
            agent: Self.wireAgent(item.agent),
            createdAt: SliceDate.required(session.createdAt, field: "created_at", record: record),
            lastActiveAt: SliceDate.required(session.lastActiveAt, field: "last_active_at", record: record),
            stateAt: Self.stateAt(item),
            live: state.live,
            stateKind: Self.wire(state.kind),
            stateCaption: caption.text, stateCaptionClipped: caption.clipped,
            stateTone: Self.wire(SessionStatePresentation.color(for: state)),
            stateGlyph: SessionStatePresentation.glyph(for: state) ?? "",
            isRing: SessionStatePresentation.isRing(state),
            openAsks: state.openAsks,
            oldestAskID: state.oldestAskID,
            closedAsks: closedAsks,
            finishSummary: finish.text, finishSummaryClipped: finish.clipped,
            agentError: error.text, agentErrorClipped: error.clipped,
            reportTargetID: summary?.targetID,
            reportDone: summary?.done,
            reportTotal: summary?.total,
            reportPRLine: prLine?.text,
            reportPRLineClipped: prLine?.clipped
        )
    }

    /// The Kit's `TerminalSessionState.Agent` raw value for the row's agent.
    static func wireAgent(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: "claude_code"
        case .codex: "codex_cli"
        }
    }

    /// When the current state was reported: the trusted hook stamp, else a
    /// finished session's `finished_at` (also one that reads Ready to check
    /// because its open asks are only checks or reviews, #534); nil when
    /// unknown.
    static func stateAt(_ item: Published) -> Date? {
        if let at = item.status?.at { return SliceDate.parse(at) }
        let finishedKinds: Set<SessionSwitcherPresentation.State.Kind> = [.finished, .readyToCheck]
        if finishedKinds.contains(item.state.kind), let finished = item.row?.finishedAt { return SliceDate.parse(finished) }
        return nil
    }

    /// The Kit's `TerminalSessionState.Kind` raw values. Agents working
    /// (#411) has no wire kind of its own: it goes out as `working`, its
    /// caption and glyph saying the rest. Ready to check (#534) has its own.
    static func wire(_ kind: SessionSwitcherPresentation.State.Kind) -> String {
        switch kind {
        case .working, .background: "working"
        case .running: "running"
        case .waitingOnAsk: "waiting_on_ask"
        case .readyToCheck: "ready_to_check"
        case .needsApproval: "needs_approval"
        case .finished: "finished"
        case .stopped: "stopped"
        case .failed: "failed"
        case .notStarted: "not_started"
        }
    }

    /// The Kit's `TerminalSessionState.Tone` raw values.
    static func wire(_ tone: SessionStatePresentation.Tone) -> String {
        switch tone {
        case .green: "green"
        case .orange: "orange"
        case .blue: "blue"
        case .red: "red"
        case .purple: "purple"
        case .secondary: "secondary"
        }
    }
}
