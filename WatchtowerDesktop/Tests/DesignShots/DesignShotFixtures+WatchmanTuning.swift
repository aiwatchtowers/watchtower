import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Scenes for the Watchman tuning spec (#2134,
/// `docs/superpowers/specs/2026-11-21-watchman-tuning-design.md`). The
/// instruction sheet in each state and the armed strip with Instruction…
/// are the real views (`WatchmanArmSheet`, `WorkbenchSessionStrip`, Task
/// 2b), as are the strip while learning, the journal's wait-for-learning
/// line (`WatchmanJournalContent`, Task 3b) and its stall cards (Task 4c).
/// Sample data only (`acme`, made-up ids).
@MainActor
enum WatchmanTuningShotFixtures {
    enum Frame: String, CaseIterable {
        case armShort = "arm-short"
        case armShortFilled = "arm-short-filled"
        case armShortSaving = "arm-short-saving"
        case armShortError = "arm-short-error"
        case armShortNearLimit = "arm-short-near-limit"
        case armFirstTime = "arm-first-time"
        case armTray = "arm-tray"
        case instructionEdit = "instruction-edit"
        case stripArmedInstruction = "strip-armed-instruction"
        case stripArmedLearning = "strip-armed-learning"
        case journalWaitingLearning = "journal-waiting-learning"
        case journalStall = "journal-stall"

        var size: NSSize {
            switch self {
            case .stripArmedInstruction, .stripArmedLearning: NSSize(width: 760, height: 0)
            case .journalWaitingLearning, .journalStall: NSSize(width: 720, height: 0)
            default: NSSize(width: 480, height: 0)
            }
        }

        @MainActor @ViewBuilder var view: some View {
            switch self {
            case .armShort: InstructionSheetShot(content: InstructionSheetShot.short)
            case .armShortFilled: InstructionSheetShot(content: InstructionSheetShot.short, text: Copy.sampleInstruction)
            case .armShortSaving:
                InstructionSheetShot(content: InstructionSheetShot.short, text: Copy.sampleInstruction, busy: true)
            case .armShortError:
                InstructionSheetShot(content: InstructionSheetShot.short, text: Copy.sampleInstruction,
                                     error: WatchmanArmingCopy.saveFailed(Copy.saveFailedReason))
            case .armShortNearLimit: InstructionSheetShot(content: InstructionSheetShot.short, text: Copy.longInstruction)
            case .armFirstTime: InstructionSheetShot(content: InstructionSheetShot.firstTime)
            case .armTray: InstructionSheetShot(content: InstructionSheetShot.tray)
            case .instructionEdit:
                InstructionSheetShot(content: .edit(subject: Copy.session), text: Copy.sampleInstruction)
            case .stripArmedInstruction: WatchmanArmingShotFixture.strip(armed: true, instructions: Copy.sampleInstruction)
            case .stripArmedLearning:
                // 777 of 1 850 decisions written: 42%.
                WatchmanArmingShotFixture.strip(armed: true, instructions: Copy.sampleInstruction,
                                                learning: (written: 777, estimated: 1850))
            case .journalWaitingLearning: JournalWaitingShot()
            case .journalStall: JournalStallShot()
            }
        }
    }

    static var shots: [DesignShot] {
        Frame.allCases.map { frame in
            DesignShot(name: "watchman-tuning-\(frame.rawValue)", size: frame.size) { AnyView(frame.view) }
        }
    }
}

/// The spec's strings, one place, pinned by `WatchmanTuningMockCopyTests`
/// (which also checks the implemented ones against `WatchmanArmingCopy`).
enum WatchmanTuningMockCopy {
    static let icon = "shield.lefthalf.filled"
    static let sheetTitle = "Hand to Watchman"
    static let editTitle = "Instruction for Watchman"
    static let fieldLabel = "Instruction for Watchman (optional)"
    static let placeholder = "What this session is for, what to prefer, what to leave to you — "
        + "e.g. \"ship task 3 only; ask me before touching the schema\""
    static let handOver = "Hand over"
    static let save = "Save"
    static let cancel = "Cancel"
    static let saveFailedReason = "the database is busy — try again"
    static let saveFailed = "Could not save: the database is busy — try again"
    static let session = "#41 Ship task 3 of the billing plan"
    static let traySessions = ["#41 Ship task 3 of the billing plan", "#42 Fix the login redirect",
                               "#43 Spec: export to CSV", "#44 Bump the parser", "#45 Review the cache layer",
                               "#46 Flaky upload test", "#47 Docs: install guide", "#48 Retry on 429"]
    static func trayHeader(_ n: Int) -> String { WatchmanArmingCopy.sessionsHeader(n) }
    static let sampleInstruction = "Ship task 3 only, then finish.\nAsk me before touching the schema."
    static let longInstruction = String(repeating: "Prefer the smaller change; keep the public API as is. ", count: 34)
    static func counter(_ n: Int) -> String { "\(n) / 2000" }
    static let learningLine = "Watchman learns this workbench first (about 1,850 decisions). Questions asked meanwhile "
        + "wait and are decided once it finishes — or answer them yourself."
    static let stripLearning = "Watchman · learning 42%"
    static let instructionButton = "Instruction…"
    static let takeBack = "Take back"
    static let waitingLearning = "Waiting for learning (42%): 3 questions"
    static let waitingHeader = "WAITING FOR YOU"
    static let stallTitle = "#41 Ship task 3 of the billing plan"
    static let stallReason = "The agent stopped and did not go on after 3 pings"
    static let stallReasonStuck = "The agent stopped and Watchman could not get a ping through for 9 minutes"
    static let stallMeta = "acme-api · 02:14 · stopped"
    static let openSession = "Open session"
    static let markDone = "Mark done"
}

private typealias Copy = WatchmanTuningMockCopy

// MARK: - The instruction sheet

/// The real `WatchmanArmSheet` in one state: the content its hand-over or
/// Instruction… builds, the field's text, busy or failed.
private struct InstructionSheetShot: View {
    let content: WatchmanArmSheetContent
    var text = ""
    var busy = false
    var error: String?

    /// A later hand-over of session #41: the short sheet.
    static let short = WatchmanArmSheetContent.handOver(
        .session(41), workbench: "acme-api", reply: WatchmanArmReply(), subject: Copy.session, sessions: [])
    /// The first hand-over on acme-api: what turns on, the learning line.
    static let firstTime = WatchmanArmSheetContent(
        workbench: "acme-api",
        reply: WatchmanArmReply(firstTime: true,
                                estimate: WatchmanEstimate(decisions: 1850, needLabels: 1200, tokens: 1_600_000)),
        sessions: [Copy.session])
    /// The tray's sheet over eight running sessions: the list scrolls past six.
    static let tray = WatchmanArmSheetContent.handOver(
        .allRunning, workbench: nil, reply: WatchmanArmReply(sessions: Array(41...48)), subject: "",
        sessions: Copy.traySessions)

    var body: some View {
        WatchmanArmSheet(content: content, instruction: text, busy: busy, error: error, onCancel: {}, onConfirm: { _ in })
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .detailBackground()
    }
}

// MARK: - The journal

/// The real journal tonight while acme-api learns (42%): three questions
/// queued for it, one decision made before.
private struct JournalWaitingShot: View {
    var body: some View {
        WatchmanJournalContent(model: Self.model(), scrolls: false)
    }

    private static func model() -> WatchmanJournalViewModel {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        func at(_ text: String) -> Date { AutomationDates.parse(text) ?? .distantPast }
        func item(_ id: Int64, _ created: String, kind: String = "ask", state: String, question: String) -> WatchmanItem {
            WatchmanItem(id: id, workbenchName: "acme-api", sessionID: 41, kind: kind, state: state,
                         outcome: state == "done" ? "answered" : "", question: question,
                         choice: state == "done" ? "Per workbench" : "", confidence: "high", category: "design",
                         unsure: false, costUSD: state == "done" ? 0.4 : 0, createdAt: at(created),
                         decidedAt: state == "done" ? at(created).addingTimeInterval(60) : nil)
        }
        let decided = item(1840, "2026-11-16T22:10:00Z", state: "done", question: "Store the window per workbench?")
        let queued = [
            item(1841, "2026-11-17T01:05:00Z", state: "queued", question: "Which store for the export cache?"),
            item(1842, "2026-11-17T01:40:00Z", kind: "check", state: "queued", question: "Check the CSV export"),
            item(1843, "2026-11-17T02:20:00Z", kind: "handover", state: "queued", question: "Left: the CSV import")
        ]
        let night = WatchmanNight(date: at("2026-11-16T12:00:00Z"), decided: [decided], pending: queued, costUSD: 0.4)
        let now = at("2026-11-17T03:00:00Z")
        let vm = WatchmanJournalViewModel(read: { throw CancellationError() }, now: { now }, calendar: utc)
        vm.apply(.success(.init(nights: [night], deciding: [], waitingForLearning: [1: queued.count])))
        vm.learningPercents = [1: 42]
        return vm
    }
}

/// The real journal tonight with two stalled sessions under Waiting for
/// you, one per stall reason (tuning spec §4b).
private struct JournalStallShot: View {
    var body: some View {
        WatchmanJournalContent(model: Self.model(), scrolls: false)
    }

    private static func model() -> WatchmanJournalViewModel {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        func at(_ text: String) -> Date { AutomationDates.parse(text) ?? .distantPast }
        func stall(_ id: Int64, session: Int64, title: String, reason: String, _ parked: String) -> WatchmanItem {
            WatchmanItem(id: id, workbenchName: "acme-api", sessionID: session, sessionTitle: title, kind: "stall",
                         outcome: "parked", parkReason: reason, createdAt: at(parked), decidedAt: at(parked))
        }
        let waiting = [
            stall(1850, session: 41, title: "Ship task 3 of the billing plan", reason: Copy.stallReason,
                  "2026-11-17T02:14:00Z"),
            stall(1851, session: 42, title: "Fix the login redirect", reason: Copy.stallReasonStuck,
                  "2026-11-17T02:40:00Z")
        ]
        let night = WatchmanNight(date: at("2026-11-16T12:00:00Z"), waiting: waiting)
        let now = at("2026-11-17T03:00:00Z")
        let vm = WatchmanJournalViewModel(read: { throw CancellationError() }, now: { now }, calendar: utc)
        vm.apply(.success(.init(nights: [night], deciding: [])))
        return vm
    }
}
