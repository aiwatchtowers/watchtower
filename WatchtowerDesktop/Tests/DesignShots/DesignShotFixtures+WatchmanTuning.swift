import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Design-only scenes for the Watchman tuning spec (#2134,
/// `docs/superpowers/specs/2026-11-21-watchman-tuning-design.md`): the
/// instruction sheet in each state, the armed strip with Instruction… and
/// while learning, the journal's wait-for-learning line and a stall card.
/// Strings are `WatchmanTuningMockCopy`; the implementation moves them into
/// `WatchmanArmingCopy` / the journal model and pins them there.
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
            case .armShort: InstructionSheetMock(state: .idle, text: "")
            case .armShortFilled: InstructionSheetMock(state: .idle, text: Copy.sampleInstruction)
            case .armShortSaving: InstructionSheetMock(state: .saving, text: Copy.sampleInstruction)
            case .armShortError: InstructionSheetMock(state: .failed, text: Copy.sampleInstruction)
            case .armShortNearLimit: InstructionSheetMock(state: .idle, text: Copy.longInstruction, count: 1912)
            case .armFirstTime: InstructionSheetMock(state: .idle, text: "", firstTime: true)
            case .armTray: InstructionSheetMock(state: .idle, text: "", sessions: Copy.traySessions)
            case .instructionEdit: InstructionSheetMock(state: .idle, text: Copy.sampleInstruction, edit: true)
            case .stripArmedInstruction: StripMock(learning: false)
            case .stripArmedLearning: StripMock(learning: true)
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

/// The spec's strings, one place, pinned by `WatchmanTuningMockCopyTests`.
enum WatchmanTuningMockCopy {
    static let icon = "binoculars"
    static let sheetTitle = "Hand to Watchman"
    static let editTitle = "Instruction for Watchman"
    static let fieldLabel = "Instruction for Watchman (optional)"
    static let placeholder = "What this session is for, what to prefer, what to leave to you — "
        + "e.g. \"ship task 3 only; ask me before touching the schema\""
    static let handOver = "Hand over"
    static let save = "Save"
    static let cancel = "Cancel"
    static let retry = "Retry"
    static let saveFailed = "Could not save: the database is busy — try again"
    static let session = "#41 Ship task 3 of the billing plan"
    static let traySessions = ["#41 Ship task 3 of the billing plan", "#42 Fix the login redirect",
                               "#43 Spec: export to CSV", "#44 Bump the parser", "#45 Review the cache layer",
                               "#46 Flaky upload test", "#47 Docs: install guide", "#48 Retry on 429"]
    static func trayHeader(_ n: Int) -> String { WatchmanArmingCopy.sessionsHeader(n) }
    static let sampleInstruction = "Ship task 3 only, then finish.\nAsk me before touching the schema."
    static let longInstruction = String(repeating: "Prefer the smaller change; keep the public API as is. ", count: 34)
    static func counter(_ n: Int) -> String { "\(n) / 2000" }
    static let firstTimeTitle = "Hand acme-api sessions to Watchman"
    static let firstTimeBody = "Watchman answers this session's asks, permission prompts and reviews the way you would, "
        + "and notes every decision in the journal for the morning."
    static let learningLine = "Watchman learns this workbench first (about 1,850 decisions). Questions asked meanwhile "
        + "wait and are decided once it finishes — or answer them yourself."
    static let analyticsLine = "Agent analytics turned on — Watchman learns from your sessions"
    static let limitsLine = "Merges to main, releases, pushes of tags and outward messages always wait for you"
    static let stripArmed = "Watchman · Sleep since 23:10"
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

private struct InstructionSheetMock: View {
    enum State { case idle, saving, failed }
    let state: State
    let text: String
    var count: Int?
    var firstTime = false
    var edit = false
    var sessions: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(edit ? Copy.editTitle : (firstTime ? Copy.firstTimeTitle : Copy.sheetTitle))
                    .font(.title3.weight(.semibold))
                if !sessions.isEmpty {
                    Text(Copy.trayHeader(sessions.count)).font(.callout.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sessions, id: \.self) { session in
                                Text(session).font(.callout).lineLimit(1).frame(minHeight: ListLayout.lineMinHeight)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: CGFloat(min(sessions.count, 6)) * ListLayout.lineMinHeight)
                } else if firstTime {
                    Text(Copy.firstTimeBody).font(.callout).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(Copy.session, systemImage: "terminal").font(.callout).foregroundStyle(.secondary)
                }
            }
            if firstTime {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    line("chart.bar", Copy.analyticsLine)
                    line(Copy.icon, Copy.learningLine)
                    line("hand.raised", Copy.limitsLine)
                }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.fieldLabel).font(.headline)
                ZStack(alignment: .topLeading) {
                    TextField("", text: .constant(text), axis: .vertical)
                        .textFieldStyle(.kit)
                        .lineLimit(3...8)
                        .disabled(state == .saving)
                    if text.isEmpty {
                        Text(Copy.placeholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Spacing.compact)
                            .padding(.vertical, Spacing.small)
                            .allowsHitTesting(false)
                    }
                }
                if let count {
                    Text(Copy.counter(count)).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if state == .failed {
                    HStack(spacing: Spacing.small) {
                        Label(Copy.saveFailed, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Tone.warning)
                        Button(Copy.retry) {}.buttonStyle(.kitQuiet).fixedSize()
                    }
                }
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button(Copy.cancel) {}.buttonStyle(.kitSecondary).disabled(state == .saving)
                Button {} label: {
                    HStack(spacing: Spacing.small) {
                        if state == .saving { ProgressView().controlSize(.mini) }
                        Text(edit ? Copy.save : Copy.handOver)
                    }
                }
                .buttonStyle(.kitPrimary)
                .disabled(state == .saving)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: IconSize.composer)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The session strip

private struct StripMock: View {
    let learning: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text(Copy.session).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: Spacing.regular)
                Chip(text: learning ? Copy.stripLearning : Copy.stripArmed, color: watchmanTone, dot: true).fixedSize()
                Button {} label: { Label(Copy.instructionButton, systemImage: "text.quote") }
                    .buttonStyle(.kitSecondary).fixedSize()
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
