import Foundation
import WatchtowerKit
import WatchtowerSync

/// The start sheet's editable fields. The brief is the target's work-on
/// prompt; it goes on the wire only from a phone allowed to type, and only
/// when edited (an unedited, possibly clipped prompt would replace the
/// Mac's full one).
struct StartSessionDraft: Equatable {
    static let briefLimit = 4_000

    var targetID: Int64?
    /// The work-on prompt the brief was filled from.
    private(set) var prefill = ""
    var brief = "" {
        didSet {
            if brief.count > Self.briefLimit { brief = String(brief.prefix(Self.briefLimit)) }
        }
    }
    /// "Bring the window forward on the Mac": off.
    var bringForward = false
    /// "Plan first, then ask me": on.
    var planFirst = true

    init(target: WorkbenchTarget?) {
        targetID = target?.id
        prefill = target?.workOnPrompt ?? ""
        brief = prefill
    }

    /// A newly picked target: the brief is its work-on prompt again.
    mutating func pick(_ target: WorkbenchTarget) {
        targetID = target.id
        prefill = target.workOnPrompt
        brief = prefill
    }

    func params(workbenchID: Int64, mode: SessionStartParams.Mode, grant: StartGrant) -> SessionStartParams {
        let edited = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let sendsBrief = grant.typingAllowed && !edited.isEmpty && brief != prefill
        return SessionStartParams(
            workbenchID: workbenchID, mode: mode, planFirst: planFirst, bringForward: bringForward,
            brief: sendsBrief ? brief : nil
        )
    }
}

/// The start sheet (spec §6.5, §13 B6) for one workbench: the target (fixed
/// from a target's detail, picked from the Workbench header), the agent,
/// the brief, the two toggles, an existing session's Open it / Start a new
/// one, and the start's progress once one was sent.
struct StartSessionFormModel {
    struct TargetOption: Equatable, Identifiable {
        let id: Int64
        let label: String
    }

    /// A session already on the target: "Open it" opens a live one on the
    /// phone and resumes a stopped one on the Mac.
    struct ExistingSession: Equatable {
        let id: Int64
        let title: String
        let caption: String
        let isLive: Bool
    }

    let workbenchID: Int64
    let workbenchName: String
    let target: WorkbenchTarget?
    /// "#415 Archive Closed Targets Now".
    let targetLabel: String?
    /// The live targets the header's New session can start, in board order.
    let targetOptions: [TargetOption]
    /// The agent Start runs (`SessionStartText.agentName`).
    let agent: String
    let grant: StartGrant
    /// Why the brief cannot be edited here; nil when it can.
    let briefCaption: String?
    let existing: ExistingSession?
    let progress: StartProgressModel?
    /// Start (and Open it, Start a new one) can send.
    let canStart: Bool
    /// Why starting is off: the grant first, then a missing target; nil when it is on.
    let startCaption: String?

    init?(
        workbenchID: Int64,
        targetID: Int64?,
        snapshot: WorkbenchReplicaSnapshot,
        grant: DeviceGrant?,
        attempt: StartAttempt?,
        inFlight: Set<String>,
        now: Date
    ) {
        guard let workbench = snapshot.workbench(workbenchID) else { return nil }
        self.workbenchID = workbenchID
        workbenchName = workbench.name
        agent = SessionStartText.agentName(workbench)
        let target = targetID.flatMap { id in snapshot.targets.first { $0.id == id && $0.workbenchID == workbenchID } }
        self.target = target
        targetLabel = target.map { "#\($0.id) \($0.text)" }
        targetOptions = NewBoardTargetDraft.parentOptions(workbenchID: workbenchID, snapshot: snapshot)
            .map { TargetOption(id: $0.id, label: $0.label) }
        let grant = StartGrant(grant)
        self.grant = grant
        if !grant.typingAllowed {
            briefCaption = SessionStartText.briefReadOnly
        } else {
            briefCaption = target?.workOnPromptClipped == true ? SessionStartText.clippedBrief : nil
        }
        existing = target.flatMap { Self.existingSession(of: $0, in: snapshot, now: now) }
        progress = target.flatMap { StartProgressModel.of(targetID: $0.id, attempt: attempt, snapshot: snapshot, now: now) }
        let sending = target.map { inFlight.contains(SessionStarter.startKey($0.id)) } ?? false
        canStart = target.map { !$0.archived } == true && grant.startSessionsAllowed && !sending
        startCaption = if !grant.startSessionsAllowed {
            SessionStartText.notAllowed
        } else if target == nil {
            SessionStartText.chooseTarget
        } else {
            nil
        }
    }

    /// The target's session: a live one first, then the latest active.
    static func existingSession(of target: WorkbenchTarget, in snapshot: WorkbenchReplicaSnapshot, now: Date) -> ExistingSession? {
        let ids = Set(target.sessionIDs)
        let sessions = snapshot.sessions.filter { $0.workbenchID == target.workbenchID && ($0.targetID == target.id || ids.contains($0.id)) }
        let pick = sessions.max { lhs, rhs in
            lhs.live != rhs.live ? !lhs.live : lhs.lastActiveAt < rhs.lastActiveAt
        }
        return pick.map { session in
            ExistingSession(
                id: session.id, title: session.title, caption: SessionRowModel(session, now: now).caption, isLive: session.live
            )
        }
    }

    /// What "Open it" does.
    enum OpenIt: Equatable {
        /// The session runs: its detail opens on the phone, nothing is sent.
        case show(sessionID: Int64)
        /// It does not: `open_existing` resumes it on the Mac.
        case resume
    }

    var openIt: OpenIt? {
        existing.map { $0.isLive ? .show(sessionID: $0.id) : .resume }
    }

    /// "#415 · Acme" above the progress.
    var progressHeader: String {
        [target.map { "#\($0.id)" }, workbenchName].compactMap { $0 }.joined(separator: " · ")
    }

    var toneUses: [ToneUse] {
        progress?.toneUses ?? []
    }
}
