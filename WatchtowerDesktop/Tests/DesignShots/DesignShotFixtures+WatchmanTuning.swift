import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Scenes for the Watchman tuning spec (#2134,
/// `docs/superpowers/specs/2026-11-21-watchman-tuning-design.md`). The
/// instruction sheet in each state and the armed strip with Instruction…
/// are the real views (`WatchmanArmSheet`, `WorkbenchSessionStrip`, Task
/// 2b); the strip while learning, the journal's wait-for-learning line and
/// a stall card are still design only, in `WatchmanTuningMockCopy` strings
/// that their tasks move into the copy types. Sample data only (`acme`,
/// made-up ids).
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
            case .stripArmedLearning: StripMock()
            case .journalWaitingLearning: JournalWaitingMock()
            case .journalStall: JournalStallMock()
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
    static let tonight = "Tonight"
    static let waitingLearning = "Waiting for learning (42%): 3 questions"
    static let waitingHeader = "WAITING FOR YOU"
    static let stallTitle = "#41 Ship task 3 of the billing plan"
    static let stallReason = "The agent stopped and did not go on after 3 pings"
    static let stallMeta = "acme-api · 02:14 · stopped"
    static let openSession = "Open session"
    static let markDone = "Mark done"
}

private typealias Copy = WatchmanTuningMockCopy

private let watchmanTone = Tone.status("purple")

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

// MARK: - The session strip

/// The armed strip while the workbench still learns (Task 3), design only.
private struct StripMock: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text(Copy.session).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: Spacing.regular)
                Chip(text: Copy.stripLearning, color: watchmanTone, dot: true).fixedSize()
                Button {} label: { Label(Copy.instructionButton, systemImage: "text.quote") }
                    .buttonStyle(.kitSecondary)
                    .fixedSize()
                    .help(Copy.sampleInstruction.components(separatedBy: "\n").first ?? "")
                Button(Copy.takeBack) {}.buttonStyle(.kitSecondary).fixedSize()
            }
            .controlSize(.small)
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.regular)
            Color.clear.frame(height: Spacing.hero)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }
}

// MARK: - The journal

private struct JournalWaitingMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: Copy.icon).foregroundStyle(watchmanTone)
                Text(Copy.tonight).font(.title3.weight(.semibold))
            }
            HStack(spacing: Spacing.regular) {
                ProgressView().controlSize(.small)
                Text(Copy.waitingLearning).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }
}

private struct JournalStallMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: Copy.icon).foregroundStyle(watchmanTone)
                Text(Copy.tonight).font(.title3.weight(.semibold))
            }
            Text(Copy.waitingHeader).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Image(systemName: "pause.circle").foregroundStyle(Tone.warning)
                    Text(Copy.stallTitle).font(.callout.weight(.semibold))
                }
                Text(Copy.stallReason).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(Copy.stallMeta).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: Spacing.regular) {
                    Button(Copy.openSession) {}.buttonStyle(.kitSecondary).fixedSize()
                    Button(Copy.markDone) {}.buttonStyle(.kitSecondary).fixedSize()
                }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }
}
