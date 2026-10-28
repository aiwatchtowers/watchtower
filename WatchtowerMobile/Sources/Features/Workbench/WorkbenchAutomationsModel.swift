import Foundation
import WatchtowerKit
import WatchtowerSync

/// The fixed texts of running an automation from the phone (ask #692).
enum AutomationRunText {
    static let segment = "Automations"
    static let run = "Run"
    static let running = "Running"
    static let runFailed = "Your Mac could not run the automation"
    /// The Mac allows runs from the phone with its start-sessions grant.
    static let notAllowed = "Your Mac has not allowed this phone to run automations. "
        + "On the Mac: Watchtower → Settings → Mobile → allow typing, then starting sessions."
    static let footer = "Only running is possible here. Edit, confirm or turn automations on and off on the Mac; "
        + "their results land in the Mac's Inbox."

    static func confirmTitle(_ name: String) -> String {
        "Run “\(name)” on the Mac?"
    }
}

/// A workbench's Automations segment (ask #692): its recipes as the Mac
/// published them (`Workbench.automations`), the phone's run on its way and
/// the Mac's refusal of it. Only a runnable recipe has Run, and only when
/// the Mac lets this phone start sessions.
struct WorkbenchAutomationsModel: Equatable {
    struct Row: Equatable, Identifiable {
        enum Action: Equatable {
            /// Run (with a confirmation first when `asksFirst`).
            case run
            /// The phone's run is on its way.
            case sending(String)
            /// A run is in progress on the Mac.
            case running
            /// Nothing runs from the phone: why, from the Mac's state.
            case unavailable(String)
        }

        let automation: WorkbenchAutomation
        let meta: [MetaItem]
        let action: Action
        /// The Mac's refusal of this phone's run, with Dismiss.
        let failure: Failure?

        var id: Int64 { automation.id }
        var icon: FlatRowIcon {
            .symbol(automation.kind == .scheduled ? "clock" : "bolt", tone: action == .running ? .blue : .secondary)
        }
    }

    struct Failure: Equatable {
        let message: String
        let pending: PendingAction
    }

    let rows: [Row]
    /// Set when this phone may not run: the rows show no Run.
    let notAllowed: String?

    init(workbenchID: Int64, snapshot: WorkbenchReplicaSnapshot, grant: DeviceGrant?, inFlight: Set<String>, now: Date) {
        let allowed = StartGrant(grant).startSessionsAllowed
        notAllowed = allowed ? nil : AutomationRunText.notAllowed
        let online = MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline
        rows = (snapshot.workbench(workbenchID)?.automations ?? []).map { automation in
            let entity = BoardWriter.automationRecordName(automation.id)
            let pending = snapshot.pending.filter { $0.action.kind == .automationRun && $0.entityRecordName == entity }
            let sending = inFlight.contains(BoardWriter.key(.automationRun, entity)) || pending.contains { $0.state == .pending }
            let failed = pending.last { $0.state == .failed }
            let action: Row.Action
            if sending {
                action = .sending(online ? BoardWriteText.sending : BoardWriteText.waitingForMac)
            } else {
                action = Self.action(automation.state, allowed: allowed)
            }
            return Row(
                automation: automation,
                meta: Self.meta(automation, now: now),
                action: action,
                failure: failed.map { Failure(message: SessionStartText.failure($0, fallback: AutomationRunText.runFailed), pending: $0) }
            )
        }
    }

    private static func action(_ state: WorkbenchAutomation.State, allowed: Bool) -> Row.Action {
        switch state {
        case .running: .running
        case .runnable: allowed ? .run : .unavailable("Not allowed")
        case .needsConfirmation: .unavailable("Confirm on the Mac")
        case .disabled: .unavailable("Off")
        case .parseError: .unavailable("Can't be read")
        default: .unavailable("Open on the Mac")
        }
    }

    /// "Button · asks first · Succeeded 2 hr ago".
    private static func meta(_ automation: WorkbenchAutomation, now: Date) -> [MetaItem] {
        var items: [MetaItem] = []
        switch automation.kind {
        case .button: items.append(MetaItem(text: "Button", tone: .secondary, role: .info))
        case .scheduled: items.append(MetaItem(text: "Scheduled", tone: .secondary, role: .info))
        default: items.append(MetaItem(text: "Manual", tone: .secondary, role: .info))
        }
        if automation.asksFirst { items.append(MetaItem(text: "asks first", tone: .secondary, role: .info)) }
        if let status = automation.lastRunStatus {
            var text = statusText(status)
            if let at = automation.lastRunAt { text += " " + ageFormatter.localizedString(for: at, relativeTo: now) }
            items.append(MetaItem(text: text, tone: statusTone(status), role: .status))
        }
        return items
    }

    /// `automation_runs.status` as the Mac's card names it
    /// (`AutomationCardPresentation.statusText`).
    static func statusText(_ status: String) -> String {
        switch status {
        case "succeeded": "Succeeded"
        case "failed": "Failed"
        case "budget_exceeded": "Budget exceeded"
        case "timed_out": "Timed out"
        case "cancelled": "Cancelled"
        case "expired": "Expired"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The Mac's badge colours, except over budget: orange is the phone's
    /// waiting-for-you tone only (`OrangeToneTests`), so it reads red here.
    private static func statusTone(_ status: String) -> PhoneTone {
        switch status {
        case "succeeded": .green
        case "failed", "timed_out", "expired", "budget_exceeded": .red
        default: .secondary
        }
    }

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
