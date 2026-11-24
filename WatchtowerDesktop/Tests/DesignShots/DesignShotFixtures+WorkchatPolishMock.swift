import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Workchat polish spec (#2201), design only: quiet steps, agent-text
/// highlighting, the agent-finished row, clipboard paste and the held line.
/// Colour sits on text only, muted (D3): no fills, pills or bold for a
/// highlight. Static mock data; no production view or model is used or changed.
struct WorkchatPolishMock {
    enum Steps { case none, collapsed, expanded }

    enum Feed {
        case dialog
        case highlights
        case finished
        case held(idle: Bool)
        case empty
        case loading
        case error
    }

    enum Composer { case placeholder, menu, pasted }

    var feed: Feed
    var steps: Steps = .collapsed
    var composer: Composer = .placeholder
    var narrow = false

    /// No turn running: the caption row keeps only the 👥 button and no clock.
    var idle: Bool { steps == .none }

    // MARK: - States (spec §Mockups)

    static let stepsCollapsed = Self(feed: .dialog)
    static let stepsExpanded = Self(feed: .dialog, steps: .expanded)
    static let stepsNarrow = Self(feed: .dialog, steps: .expanded, narrow: true)
    static let highlights = Self(feed: .highlights, steps: .none)
    static let finished = Self(feed: .finished, steps: .none)
    static let pasteMenu = Self(feed: .dialog, steps: .none, composer: .menu)
    static let pasted = Self(feed: .dialog, steps: .none, composer: .pasted)
    static let heldIdle = Self(feed: .held(idle: true), steps: .none)
    static let heldWorking = Self(feed: .held(idle: false))
    static let empty = Self(feed: .empty, steps: .none)
    static let loading = Self(feed: .loading, steps: .none)
    static let error = Self(feed: .error, steps: .none)
}

/// The spec's `SyntaxTint`, mocked here (it is not in DesignKit yet): one
/// semantic colour per span kind at a muted text opacity, foreground only.
enum WorkchatPolishTint {
    /// The builder picks the real value (spec "Left to the builder").
    static let mutedOpacity = 0.7
    static let ref = Color.accentColor.opacity(mutedOpacity)
    static let hash = Color.purple.opacity(mutedOpacity)
    static let path = Color.orange.opacity(mutedOpacity)
    static let command = Color.green.opacity(mutedOpacity)
    /// The tertiary label colour, for the quietest text button.
    static let tertiary = Color(nsColor: .tertiaryLabelColor)

    /// A text button in a grey label (D3: grey text actions, not accent).
    static func textButton(_ label: Color) -> KitQuietButtonStyle { KitQuietButtonStyle(label: label) }
}

/// The copy the mockups draw, in one place.
enum WorkchatPolishCopy {
    static let turnTitle = "This turn · 41 steps"
    static let runningStep = "Run full Go test suite for #2188 gate"
    static let runningStepTime = "3:34"
    static let turnClock = "36:34"
    static let earlierSteps = "35 earlier steps"
    static let placeholder = "Message the agent… (/ for commands)"
    static let noMessages = "No messages yet"
    static let loading = "Reading the session…"
    static let error = "Couldn’t read the session feed"
    static let errorDetail = "The session host did not answer."
    static let retry = "Retry"
    static let heldCaption = "Waiting: the terminal prompt holds text"
    static let heldPrompt = "> look at the window test again"
    static let clearAndSend = "Clear and send"
    static let sendTogether = "Send together"
    static let cancel = "Cancel"
    static let heldLine = "Run the gate."
    static let pasteScreenshot = "Paste screenshot"
    static let attachFiles = "Attach files…"
    static let pastedText = "here is what fails, take a look"
    static let resultLabel = "RESULT"
    static let openOutput = "Open output"
    static let details = "Details"

    struct Step: Identifiable {
        let id: Int
        let symbol: String
        let summary: String
        let time: String
        var running = false
    }

    /// The last six steps of the turn; the running one at the bottom (spec §1).
    static let steps = [
        Step(id: 1, symbol: "person.2", summary: "Codex verify round 3 #2188", time: "0:41"),
        Step(id: 2, symbol: "terminal", summary: "List CI workflow jobs and their run commands", time: "<1s"),
        Step(id: 3, symbol: "terminal", summary: "List remaining CI jobs (Swift side)", time: "<1s"),
        Step(id: 4, symbol: "doc.text", summary: "Read CI gate path filters", time: "<1s"),
        Step(id: 5, symbol: "paperplane", summary: "Message to Codex verify round 3", time: "<1s"),
        Step(id: 6, symbol: "terminal", summary: runningStep, time: runningStepTime, running: true)
    ]

    static let dialog: [(owner: Bool, text: String)] = [
        (true, "Review the round 3 diff and run the gate when it is clean."),
        (false, "Round 3 of #2188 is ready. The last diff is small, so I am reading it myself and Codex runs in parallel."),
        (false, "Codex found no blockers. The full gate for #2188 is running now: about 30–40 minutes.")
    ]
}

/// A run of an agent message: plain text, or a span the scanner marks (spec §2).
enum WorkchatPolishRun {
    case text(String)
    case ref(String)
    case hash(String)
    case path(String)
    case command(String)
    /// Inline code that is not a command: drawn as today, untouched.
    case code(String)
}

@MainActor
enum WorkchatPolishMockShotFixtures {
    static let shots: [DesignShot] = [
        shot("01-steps-collapsed", .stepsCollapsed),
        shot("02-steps-expanded", .stepsExpanded),
        shot("03-steps-narrow", .stepsNarrow, width: 340),
        shot("04-agent-text-highlights", .highlights),
        shot("05-agent-finished", .finished, height: 560),
        shot("06-paste-menu", .pasteMenu),
        shot("07-pasted", .pasted),
        shot("08-held-idle", .heldIdle),
        shot("09-held-working", .heldWorking),
        shot("10-empty", .empty, height: 360),
        shot("11-loading", .loading, height: 360),
        shot("12-error", .error, height: 360)
    ]

    private static func shot(_ name: String, _ mock: WorkchatPolishMock, width: CGFloat = 720, height: CGFloat = 480) -> DesignShot {
        DesignShot(name: "workchat-polish-\(name)", size: NSSize(width: width, height: height)) {
            AnyView(WorkchatPolishMockShot(mock: mock))
        }
    }
}

/// The Workchat pane as the spec draws it: feed, optional steps list, live
/// line, composer; the paperclip menu floats over the composer when open.
@MainActor
struct WorkchatPolishMockShot: View {
    let mock: WorkchatPolishMock

    var body: some View {
        VStack(spacing: 0) {
            feed
            if mock.steps == .expanded { WorkchatPolishStepsMock() }
            if !mock.idle { WorkchatPolishLiveLineMock(expanded: mock.steps == .expanded, narrow: mock.narrow) }
            composer
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailBackground()
        .overlay(alignment: .bottomLeading) {
            if mock.composer == .menu {
                WorkchatPolishPasteMenuMock()
                    .padding(.leading, Spacing.large)
                    .padding(.bottom, Spacing.hero + Spacing.large)
            }
        }
    }

    @ViewBuilder private var feed: some View {
        switch mock.feed {
        case .empty:
            Text(WorkchatPolishCopy.noMessages)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            VStack(spacing: Spacing.regular) {
                ProgressView().controlSize(.small)
                Text(WorkchatPolishCopy.loading).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error:
            errorState
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.large) { feedRows }
                    .padding(Spacing.large)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private var feedRows: some View {
        switch mock.feed {
        case .highlights:
            WorkchatPolishHighlightsMock()
        case .finished:
            ownerBubble("Get both reviews on round 3 and tell me what they found.")
            agentText("Two reviews are out: a Claude verify pass and a Codex round. I will fold them into one answer.")
            WorkchatPolishFinishedMock()
        case .held(let idle):
            dialog
            WorkchatPolishHeldLineMock(idle: idle)
        default:
            dialog
        }
    }

    @ViewBuilder private var dialog: some View {
        ForEach(Array(WorkchatPolishCopy.dialog.enumerated()), id: \.offset) { _, message in
            if message.owner { ownerBubble(message.text) } else { agentText(message.text) }
        }
    }

    private func ownerBubble(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(Tone.status("blue").opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.bubble))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, Spacing.hero)
    }

    private func agentText(_ text: String) -> some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Today's error bar is an orange box; drawn quiet here (D3): a tinted
    /// glyph, grey text and a soft Retry, centred where the feed would be.
    private var errorState: some View {
        VStack(spacing: Spacing.regular) {
            HStack(spacing: Spacing.compact) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Tone.warning)
                Text(WorkchatPolishCopy.error).foregroundStyle(.secondary)
            }
            Text(WorkchatPolishCopy.errorDetail).font(.caption).foregroundStyle(.tertiary)
            Button(WorkchatPolishCopy.retry) {}.buttonStyle(.kitSecondary).controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if mock.composer == .pasted {
                WorkchatPolishFileChipMock(name: "gate.log", detail: "84 KB")
            }
            HStack(spacing: Spacing.compact) {
                Image(systemName: "paperclip").foregroundStyle(mock.composer == .menu ? .primary : .secondary)
                if mock.composer == .pasted {
                    HStack(spacing: Spacing.small) {
                        WorkchatPolishTokenMock(label: "Image #1", symbol: "photo")
                        Text(WorkchatPolishCopy.pastedText)
                        WorkchatPolishTokenMock(label: "Pasted text #2 +212 lines", symbol: "doc.plaintext")
                    }
                    .lineLimit(1)
                } else {
                    Text(WorkchatPolishCopy.placeholder).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: Spacing.compact)
                Image(systemName: mock.idle || mock.composer == .pasted ? "arrow.up" : "stop.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tone.status("blue"))
                    .frame(width: IconSize.composerLarge, height: IconSize.composerLarge)
            }
        }
        .padding(Spacing.cozy)
        .background(Surface.text, in: RoundedRectangle(cornerRadius: Radius.control))
        .padding(.horizontal, Spacing.large)
        .padding(.bottom, Spacing.large)
    }
}

/// The live line (spec §1). Collapsed: the running step and its own time
/// inline. Expanded: only the title, the list above carries the steps.
struct WorkchatPolishLiveLineMock: View {
    let expanded: Bool
    let narrow: Bool

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: IconSize.chevron, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: IconSize.header)
            Text(WorkchatPolishCopy.turnTitle).fixedSize()
            if !expanded {
                Text("·").foregroundStyle(.tertiary)
                ProgressView().controlSize(.mini)
                Text(WorkchatPolishCopy.runningStep)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(WorkchatPolishCopy.runningStepTime).monospacedDigit().foregroundStyle(.tertiary).fixedSize()
            }
            Spacer(minLength: Spacing.compact)
            HStack(spacing: Spacing.small) {
                Image(systemName: "person.2")
                Text("1").monospacedDigit()
            }
            .padding(.horizontal, Spacing.compact)
            Text(WorkchatPolishCopy.turnClock).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: ListLayout.lineMinHeight)
    }
}

/// The expanded steps (spec §1): no card fill, a thin rule on the left,
/// finished rows grey, the running row bright with a mini spinner.
struct WorkchatPolishStepsMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(WorkchatPolishCopy.earlierSteps)
                .foregroundStyle(.tertiary)
                .frame(height: ListLayout.lineMinHeight)
            ForEach(WorkchatPolishCopy.steps) { step in
                HStack(spacing: Spacing.compact) {
                    Group {
                        if step.running {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: step.symbol)
                        }
                    }
                    .frame(width: IconSize.header)
                    Text(step.summary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Spacing.compact)
                    Text(step.time)
                        .monospacedDigit()
                        .foregroundStyle(step.running ? .secondary : .tertiary)
                }
                .foregroundStyle(step.running ? .primary : .tertiary)
                .frame(height: ListLayout.lineMinHeight)
            }
        }
        .font(.caption)
        .padding(.leading, Spacing.medium)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: Stroke.hairline * 2)
        }
        // The rule sits under the live line's chevron.
        .padding(.leading, Spacing.large + IconSize.header / 2)
        .padding(.trailing, Spacing.large)
        .padding(.bottom, Spacing.small)
    }
}

/// Agent messages with the scanner's spans coloured (spec §2).
struct WorkchatPolishHighlightsMock: View {
    private static let messages: [[WorkchatPolishRun]] = [
        [.text("Round 3 of "), .ref("#2188"), .text(" is ready ("), .hash("67a59755a"),
         .text("). The last diff is small, so I am reading it myself and Codex runs in parallel.")],
        [.text("For "), .ref("#2188"), .text(" the whole gate runs: "), .command("make test"), .text(", "),
         .command("make test-swift"), .text(", "), .command("make lint-all"),
         .text(", the leak check and the guide check. About 30–40 minutes.")],
        [.ref("#2189"), .text(" is still with the implementer. The SourceKit error in "),
         .path("CloudKitTransport+LinkDirect.swift"), .text(" is indexer noise again, not a build error.")],
        [.text("Codex found no blockers. One gap: no test covers the hidden-window → "), .code(".gone"),
         .text(" transition; see "), .path("internal/sessionhost/prompt_state.go"), .text(".")]
    ]

    var body: some View {
        ForEach(Array(Self.messages.enumerated()), id: \.offset) { _, runs in
            Text(Self.attributed(runs)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func attributed(_ runs: [WorkchatPolishRun]) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            switch run {
            case .text(let text): out += AttributedString(text)
            case .ref(let text): out += span(text, WorkchatPolishTint.ref, mono: false)
            case .hash(let text): out += span(text, WorkchatPolishTint.hash, mono: true)
            case .path(let text): out += span(text, WorkchatPolishTint.path, mono: true)
            case .command(let text): out += span(text, WorkchatPolishTint.command, mono: true)
            case .code(let text):
                var code = AttributedString(text)
                code.font = .callout.monospaced()
                out += code
            }
        }
        return out
    }

    private static func span(_ text: String, _ tint: Color, mono: Bool) -> AttributedString {
        var span = AttributedString(text)
        span.foregroundColor = tint
        if mono { span.font = .callout.monospaced() }
        return span
    }
}

/// Agent-finished rows (spec §3): collapsed, expanded, failed, and a
/// background command, smaller. A tinted glyph, no badge or fill.
struct WorkchatPolishFinishedMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            row(glyph: "checkmark", tint: Tone.success, title: "Claude verify review ",
                meta: "finished · 9 tools · 43.5k tokens · 1m 29s", open: false)
            VStack(alignment: .leading, spacing: 0) {
                row(glyph: "checkmark", tint: Tone.success, title: "Claude verify review ",
                    meta: "finished · 9 tools · 43.5k tokens · 1m 29s", open: true)
                expandedBody
            }
            row(glyph: "xmark", tint: Tone.error, title: "Codex verify round 3 ",
                meta: "failed · 2 tools · 1.2k tokens · 12s", open: false)
            commandRow
        }
        .frame(maxWidth: 480, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func row(glyph: String, tint: Color, title: String, meta: String, open: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: glyph)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint.opacity(WorkchatPolishTint.mutedOpacity))
                .frame(width: IconSize.header)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(WorkchatPolishHighlightsMock.attributed([.text(title), .ref("#2188")]))
                    .foregroundStyle(.secondary)
                Text(meta).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
            Spacer(minLength: Spacing.regular)
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: IconSize.chevron, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.small)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(WorkchatPolishCopy.resultLabel)
                .font(.caption2)
                .tracking(Tracking.caps)
                .foregroundStyle(.tertiary)
            Text(WorkchatPolishHighlightsMock.attributed([
                .text("No blockers. One test gap: the hidden-window → "), .code(".gone"), .text(" transition is not covered.")
            ]))
            HStack(spacing: Spacing.medium) {
                Button(WorkchatPolishCopy.openOutput) {}.buttonStyle(WorkchatPolishTint.textButton(.secondary))
                Button(WorkchatPolishCopy.details) {}.buttonStyle(WorkchatPolishTint.textButton(WorkchatPolishTint.tertiary))
            }
            .font(.caption)
            .padding(.top, Spacing.small)
            Text("task a1b2c3d4e5f60718 · toolu_01AbCdEf…")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, Spacing.medium)
        .padding(.vertical, Spacing.tight)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: Stroke.hairline * 2)
        }
        // The rule sits under the status glyph.
        .padding(.leading, Spacing.regular + IconSize.header / 2)
        .padding(.bottom, Spacing.small)
    }

    private var commandRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Tone.success.opacity(WorkchatPolishTint.mutedOpacity))
                .frame(width: IconSize.header)
            Text("Background command · Run full Go test suite").foregroundStyle(.secondary).lineLimit(1)
            Text("exit 0 · 3m 34s").monospacedDigit().foregroundStyle(.tertiary)
            Spacer(minLength: Spacing.regular)
            Image(systemName: "chevron.right")
                .font(.system(size: IconSize.chevron, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, Spacing.regular)
    }
}

/// An owner line held because the terminal prompt holds text (spec §6.3):
/// grey caption, the prompt's last line, text-button actions, no box.
struct WorkchatPolishHeldLineMock: View {
    let idle: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.small) {
            Text(WorkchatPolishCopy.heldLine)
                .padding(.horizontal, Spacing.cozy)
                .padding(.vertical, Spacing.compact)
                .background(Tone.status("blue").opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.bubble))
                .opacity(0.65)
            Text(WorkchatPolishCopy.heldCaption).font(.caption).foregroundStyle(.secondary)
            Text(WorkchatPolishCopy.heldPrompt).font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: Spacing.medium) {
                // Clear and send only while the agent is idle (C4).
                if idle { Button(WorkchatPolishCopy.clearAndSend) {}.buttonStyle(WorkchatPolishTint.textButton(.primary)) }
                Button(WorkchatPolishCopy.sendTogether) {}.buttonStyle(WorkchatPolishTint.textButton(.secondary))
                Button(WorkchatPolishCopy.cancel) {}.buttonStyle(WorkchatPolishTint.textButton(WorkchatPolishTint.tertiary))
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, Spacing.hero)
    }
}

/// The paperclip menu (spec §4): the paste item titled by what the clipboard holds.
struct WorkchatPolishPasteMenuMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            item(WorkchatPolishCopy.pasteScreenshot, key: "⌘V")
            item(WorkchatPolishCopy.attachFiles, key: "⇧⌘A")
        }
        .padding(Spacing.small)
        .frame(width: PaneWidth.sideListIdeal + Spacing.hero)
        .popoverSurface()
        .background(Surface.window, in: RoundedRectangle(cornerRadius: Radius.container))
        .overlay(RoundedRectangle(cornerRadius: Radius.container).strokeBorder(.quaternary, lineWidth: Stroke.hairline))
    }

    private func item(_ title: String, key: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: Spacing.regular)
            Text(key).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.regular)
        .frame(height: ListLayout.rowMinHeight)
    }
}

/// An atomic token inside the field: one Backspace removes it.
struct WorkchatPolishTokenMock: View {
    let label: String
    let symbol: String

    var body: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: symbol)
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.compact)
        .padding(.vertical, Spacing.tight)
        .background(Fill.selected, in: RoundedRectangle(cornerRadius: Radius.mark))
        .fixedSize()
    }
}

/// A Finder-copied file as an attachment chip above the field.
struct WorkchatPolishFileChipMock: View {
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(width: IconSize.tile, height: IconSize.tile)
                .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.mark))
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.caption)
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
            Image(systemName: "xmark").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(Spacing.small)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
    }
}
