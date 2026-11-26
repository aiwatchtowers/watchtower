import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// "Not clear?" on each item of an ask (board #2412), design only: a quiet
/// entry per question of a question ask and per step of a check ask, and the
/// chat opened from one item with a compact card of that item pinned under
/// its Back strip. Follows the approved `AskExplainMock` look. Static sample
/// data; no production view or model is used or changed.
struct AskExplainItemsMock {
    enum Screen: Equatable {
        /// A question ask with three questions, an entry under each.
        case questions
        /// A check ask with four steps, a "?" on each step row.
        case checks
        /// The chat opened from one item.
        case chat(Subject, Feed)
    }

    enum Subject: Equatable { case question, step, longQuestion }
    enum Feed: Equatable { case explained, loading, error }

    var screen: Screen
    var narrow = false

    // MARK: - Copy

    static let entry = "Not clear?"
    static let stepHelp = "Ask the assistant about this step"
    static let back = "Back to question"
    static let backToCheck = "Back to check"
    static let showMore = "Show more"
    static let recommended = "Recommended"
    static let retry = "Retry"
    static let turnError = "Couldn't answer: the provider did not answer in time."
    static let other = "Other…"

    // MARK: - Sample question ask

    struct Option {
        let label: String
        let detail: String
        var recommended = false
    }

    struct Question {
        let text: String
        let options: [Option]
    }

    static let questionTitle = "Guard agent writes to their own settings: three choices before it ships"
    static let questions: [Question] = [
        Question(text: "Queue the agent's writes to its own settings?", options: [
            Option(label: "Yes, queue them", detail: "The agent cannot lift its own guard from a shell", recommended: true),
            Option(label: "No, keep as is", detail: "Log it as an accepted risk")
        ]),
        Question(text: "How long does a queued write wait for you?", options: [
            Option(label: "Until you answer", detail: "The agent works on; the write lands when you approve it",
                   recommended: true),
            Option(label: "One day", detail: "After a day the write is dropped and the agent is told"),
            Option(label: "One hour", detail: "Short; most writes would be dropped overnight")
        ]),
        Question(text: "What about the writes made before the guard?", options: [
            Option(label: "List them once", detail: "One ask with every change since the workbench was made",
                   recommended: true),
            Option(label: "Leave them", detail: "Only new writes are queued")
        ])
    ]

    static let longQuestion = Question(
        text: "When a queued write waits and the agent keeps working, should the agent see its own pending change "
            + "in the files it reads (as if the write had landed), or the file as it is on disk until you approve, "
            + "knowing that a later edit of the same file may then conflict with the queued one?",
        options: [
            Option(label: "Show it the pending change", detail: "", recommended: true),
            Option(label: "Show the file on disk", detail: ""),
            Option(label: "Stop the agent until you answer", detail: "")
        ]
    )

    static let questionExplanation = [
        "When the agent writes to .mcp.json or the hooks file, the write is held and you get an ask with the diff. "
            + "This question is how long that held write waits.",
        "Until you answer: nothing is lost; the agent works on and the write lands the moment you approve it.",
        "One day or one hour: a write you did not get to is dropped and the agent is told, so it may try again "
            + "or work without it."
    ]

    static let longExplanation = [
        "While a write waits for you, the file on disk is still the old one. The question is which version "
            + "the agent reads in the meantime.",
        "Pending change: the agent keeps working as if you had approved; if you refuse, its later edits may "
            + "rest on a change that never landed.",
        "File on disk: what the agent sees is always true, but its next edit of that file can clash with the "
            + "queued one. Stopping the agent avoids both and costs its time until you answer."
    ]

    // MARK: - Sample check ask

    struct Step {
        let text: String
        let hint: String
    }

    static let checkTitle = "Check the queued settings write on a test workbench"
    static let steps: [Step] = [
        Step(text: "Open a test workbench and start an agent session.", hint: "Any scratch folder works."),
        Step(text: "Ask the agent to add an MCP server to its .mcp.json.",
             hint: "The write does not land: a new ask with the diff appears instead."),
        Step(text: "Approve the queued write from that ask.", hint: "The file now holds the new server."),
        Step(text: "Ask the agent to edit .mcp.json from a shell command.",
             hint: "Queued as well; the agent is told the write waits for you.")
    ]

    static let stepExplanation = [
        "This step checks that the guard catches the agent's own write, not only writes outside the folder.",
        "Type something like \"add the example MCP server to .mcp.json\" in the agent's session. "
            + "Works: the file is unchanged and a new ask with the diff shows up in the drawer.",
        "Doesn't work: the file changed at once, or no ask appeared — note which one."
    ]

    static let questionsState = Self(screen: .questions)
    static let checksState = Self(screen: .checks)
}

@MainActor
enum AskExplainItemsMockShotFixtures {
    static let shots: [DesignShot] = [
        shot("items-entry", .questionsState, height: 760),
        shot("check-entry", .checksState),
        shot("item-chat", .init(screen: .chat(.question, .explained))),
        shot("step-chat", .init(screen: .chat(.step, .explained))),
        shot("card-long", .init(screen: .chat(.longQuestion, .explained))),
        shot("item-narrow", .init(screen: .chat(.question, .explained), narrow: true), width: 320),
        shot("item-loading", .init(screen: .chat(.question, .loading))),
        shot("item-error", .init(screen: .chat(.question, .error)))
    ]

    private static func shot(
        _ name: String,
        _ mock: AskExplainItemsMock,
        width: CGFloat = 440,
        height: CGFloat = 620
    ) -> DesignShot {
        DesignShot(name: "ask-explain-\(name)", size: NSSize(width: width, height: height)) {
            AnyView(AskExplainItemsMockShot(mock: mock))
        }
    }
}

/// The ask drawer: its header, then either the ask (questions or steps, each
/// with its own entry) over the answer bar, or the chat about one item.
@MainActor
struct AskExplainItemsMockShot: View {
    typealias Mock = AskExplainItemsMock
    let mock: Mock

    var body: some View {
        VStack(spacing: 0) {
            header
            switch mock.screen {
            case .questions:
                askScroll { questionsBody }
                answerBar
            case .checks:
                askScroll { checksBody }
                answerBar
            case let .chat(subject, feed):
                chat(subject, feed)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailBackground()
    }

    private var isCheck: Bool {
        switch mock.screen {
        case .checks, .chat(.step, _): true
        default: false
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.compact) {
            Chip(text: isCheck ? "Check" : "Question", color: Tone.status(isCheck ? "teal" : "blue"))
            Spacer(minLength: Spacing.compact)
            Text("1 of 3").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(.secondary)
            Image(systemName: "xmark").foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
    }

    private func askScroll(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.large)
                .card()
                .padding(.horizontal, Spacing.medium)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Question ask: an entry under each question

    private var questionsBody: some View {
        VStack(alignment: .leading, spacing: Spacing.wide) {
            Text(Mock.questionTitle).font(.headline)
            ForEach(Mock.questions, id: \.text) { question in
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(question.text).fontWeight(.semibold)
                    ForEach(question.options, id: \.label) { option in
                        optionRow(option)
                    }
                    Text(Mock.other)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.regular)
                        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
                    entry
                }
            }
        }
    }

    private func optionRow(_ option: Mock.Option) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: "circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.compact) {
                    Text(option.label)
                    if option.recommended { Chip(text: Mock.recommended, color: Tone.status("blue")) }
                }
                Text(option.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Today's entry, unchanged, at the foot of its question's block.
    private var entry: some View {
        HStack {
            Spacer()
            Button {} label: {
                Label(Mock.entry, systemImage: "questionmark.circle").font(.caption)
            }
            .buttonStyle(KitQuietButtonStyle(label: .secondary))
        }
    }

    // MARK: - Check ask: a "?" on each step row

    private var checksBody: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(Mock.checkTitle).font(.headline)
            Text("0 of 4 marked").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(Mock.steps.enumerated()), id: \.offset) { index, step in
                stepRow(step, number: index + 1)
            }
        }
    }

    private func stepRow(_ step: Mock.Step, number: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(step.text)
                    Text(step.hint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.small)
                Button {} label: {
                    Image(systemName: "questionmark.circle").font(.caption)
                }
                .buttonStyle(KitQuietButtonStyle(label: .secondary))
                .help(Mock.stepHelp)
            }
            HStack(spacing: Spacing.small) {
                markChip("Works", icon: "checkmark.circle")
                markChip("Doesn't work", icon: "xmark.circle")
                markChip("Didn't check", icon: "minus.circle")
            }
            .padding(.leading, Spacing.large + Spacing.tight)
        }
    }

    private func markChip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Spacing.tight)
            .background(Fill.card, in: Capsule())
    }

    private var answerBar: some View {
        HStack(spacing: Spacing.regular) {
            Spacer()
            Button("Later") {}.buttonStyle(.kitSecondary)
            Button(isCheck ? "Send" : "Answer") {}.buttonStyle(.kitPrimary)
        }
        .controlSize(.small)
        .padding(Spacing.medium)
    }

    // MARK: - Chat about one item

    private func chat(_ subject: Mock.Subject, _ feed: Mock.Feed) -> some View {
        VStack(spacing: 0) {
            strip(subject)
            AskExplainItemCard(subject: subject)
                .padding(.horizontal, Spacing.medium)
            rows(subject, feed)
            composer(subject, streaming: feed == .loading)
        }
    }

    /// Back, and which item of the ask the chat is about: the card under it
    /// carries the item itself, so the strip no longer repeats the title.
    private func strip(_ subject: Mock.Subject) -> some View {
        HStack(spacing: Spacing.compact) {
            Button {} label: {
                Label(subject == .step ? Mock.backToCheck : Mock.back, systemImage: "chevron.left").font(.caption)
            }
            .buttonStyle(.kitQuiet)
            .fixedSize()
            Spacer(minLength: Spacing.compact)
            Text(subject == .step ? "Step 2" : "Question 2")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.bottom, Spacing.small)
    }

    private func rows(_ subject: Mock.Subject, _ feed: Mock.Feed) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                switch feed {
                case .loading:
                    TypingDots()
                case .error:
                    errorCard
                case .explained:
                    ForEach(explanation(subject), id: \.self) {
                        Text($0)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.large)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: .infinity)
    }

    private func explanation(_ subject: Mock.Subject) -> [String] {
        switch subject {
        case .question: Mock.questionExplanation
        case .step: Mock.stepExplanation
        case .longQuestion: Mock.longExplanation
        }
    }

    /// The shared ChatUI failed-reply card (spec D11): its line and Retry.
    private var errorCard: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Label(Mock.turnError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Tone.error)
            Button(Mock.retry) {}.buttonStyle(.kitSecondary).controlSize(.small)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tone.error.opacity(ChipTint.fillOpacity / 2), in: RoundedRectangle(cornerRadius: Radius.container))
    }

    private func composer(_ subject: Mock.Subject, streaming: Bool) -> some View {
        HStack(spacing: Spacing.compact) {
            Text(subject == .step ? "Ask about this step…" : "Ask about this question…")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: Spacing.compact)
            Image(systemName: streaming ? "stop.fill" : "arrow.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tone.status("blue"))
                .frame(width: IconSize.composerLarge, height: IconSize.composerLarge)
        }
        .padding(Spacing.cozy)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container))
        .padding(Spacing.medium)
    }
}

/// The compact card of what the chat is about, pinned under the strip: the
/// question and its options as one-line rows (descriptions dropped), or the
/// step and its hint. Past about four lines it is clamped with a fade and a
/// quiet Show more.
@MainActor
private struct AskExplainItemCard: View {
    typealias Mock = AskExplainItemsMock
    let subject: Mock.Subject

    /// About four lines of callout text.
    private static let clampHeight: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if subject == .longQuestion {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: Self.clampHeight, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                HStack {
                    Spacer()
                    Button {} label: {
                        Label(Mock.showMore, systemImage: "chevron.down").font(.caption)
                    }
                    .buttonStyle(KitQuietButtonStyle(label: .secondary))
                }
            } else {
                content
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private var content: some View {
        switch subject {
        case .step:
            let step = Mock.steps[1]
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Text("2.").foregroundStyle(.secondary).monospacedDigit()
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(step.text).fontWeight(.semibold).lineLimit(2)
                    Text(step.hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        case .question:
            question(Mock.questions[1], textLines: 2)
        case .longQuestion:
            question(Mock.longQuestion, textLines: nil)
        }
    }

    private func question(_ question: Mock.Question, textLines: Int?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(question.text).fontWeight(.semibold).lineLimit(textLines)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(question.options, id: \.label) { option in
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: "circle").font(.caption2).foregroundStyle(.tertiary)
                        Text(option.label).font(.caption).lineLimit(1)
                        if option.recommended { Chip(text: Mock.recommended, color: Tone.status("blue")) }
                    }
                }
            }
        }
    }
}

/// The feed's own live row while the first reply has no text (spec D10):
/// no extra "Explaining…" line.
private struct TypingDots: View {
    var body: some View {
        HStack(spacing: Spacing.small) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(index == 0 ? 0.8 : 0.4))
                    .frame(width: Spacing.compact, height: Spacing.compact)
            }
        }
        .padding(.vertical, Spacing.regular)
    }
}
