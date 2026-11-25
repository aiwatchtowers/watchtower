import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// "Not clear?" on an ask (spec 2026-11-24, board #2355), design only: the
/// ask drawer's question view with its quiet entry, and the chat that takes
/// the whole panel. Static sample data; no production view or model is used
/// or changed.
struct AskExplainMock {
    enum Feed { case queued, loading, explained, long, busy, error }

    var chat: Feed?
    var narrow = false

    // MARK: - Copy (spec §Texts)

    static let entry = "Not clear?"
    static let back = "Back to question"
    static let placeholder = "Ask about this question…"
    static let explaining = "Explaining…"
    static let queued = "Waiting — other chats are answering."
    static let errorLine = "Couldn't explain: the provider did not answer in time."
    static let retry = "Retry"
    static let emptyHint = "The assistant explains; it never changes anything."

    // MARK: - Sample ask

    static let kind = "Question"
    static let position = "1 of 3"
    static let title = "#412: queue agent writes to its own settings (.mcp.json, hooks) for your approval?"
    static let options: [(label: String, detail: String, recommended: Bool)] = [
        ("Yes, queue them", "The agent cannot lift its own guard from a shell; normal work is not affected", true),
        ("No, keep as is", "Log it as an accepted risk", false)
    ]
    static let other = "Other…"
    static let later = "Later"
    static let answer = "Answer"

    static let explanation = [
        "Right now an agent in the terminal can rewrite its own settings (.mcp.json, the hooks file) and so switch off the guard put on it.",
        "Queue means such a write is not applied at once: you get it as a separate ask with the diff and decide.",
        "Yes costs a rare extra ask; the agent can no longer disable its guard. No keeps today's behaviour, and the risk is written to the audit log."
    ]
    static let followUps: [(question: String, answer: String)] = [
        ("Will my own scripts that write .mcp.json be queued too?",
         "No. Only writes from agent sessions are queued. What you run yourself writes as before."),
        ("How often will these asks come?",
         "Rarely: an agent touches these files when it sets up a new MCP server or hook.")
    ]
    static let streamingReply = "Only when the agent adds or changes a server; reading them"

    static let entryState = Self(chat: nil)
    static let queuedState = Self(chat: .queued)
    static let loadingState = Self(chat: .loading)
    static let explainedState = Self(chat: .explained)
    static let longState = Self(chat: .long)
    static let busyState = Self(chat: .busy)
    static let errorState = Self(chat: .error)
    static let narrowState = Self(chat: .explained, narrow: true)
}

@MainActor
enum AskExplainMockShotFixtures {
    static let shots: [DesignShot] = [
        shot("entry", .entryState),
        shot("queued", .queuedState),
        shot("loading", .loadingState),
        shot("explained", .explainedState),
        shot("long", .longState),
        shot("busy", .busyState),
        shot("error", .errorState),
        shot("narrow", .narrowState, width: 320)
    ]

    private static func shot(_ name: String, _ mock: AskExplainMock, width: CGFloat = 440) -> DesignShot {
        DesignShot(name: "ask-explain-\(name)", size: NSSize(width: width, height: 620)) {
            AnyView(AskExplainMockShot(mock: mock))
        }
    }
}

/// The ask drawer as the spec draws it: the header stays; under it either
/// the question view and its answer bar, or the chat on the whole panel.
@MainActor
struct AskExplainMockShot: View {
    let mock: AskExplainMock

    var body: some View {
        VStack(spacing: 0) {
            header
            if let feed = mock.chat {
                chat(feed)
            } else {
                question
                answerBar
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailBackground()
    }

    private var header: some View {
        HStack(spacing: Spacing.compact) {
            Chip(text: AskExplainMock.kind, color: Tone.status("blue"))
            Spacer(minLength: Spacing.compact)
            Text(AskExplainMock.position).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(.secondary)
            Image(systemName: "xmark").foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
    }

    // MARK: - Question view

    private var question: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text(AskExplainMock.title).font(.headline)
                ForEach(AskExplainMock.options, id: \.label) { option in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                        Image(systemName: "circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            HStack(spacing: Spacing.compact) {
                                Text(option.label)
                                if option.recommended { Chip(text: "Recommended", color: Tone.status("blue")) }
                            }
                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(AskExplainMock.other)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: Spacing.hero * 1.5, alignment: .topLeading)
                    .padding(Spacing.regular)
                    .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
                HStack {
                    Spacer()
                    Button {} label: {
                        Label(AskExplainMock.entry, systemImage: "questionmark.circle").font(.caption)
                    }
                    .buttonStyle(KitQuietButtonStyle(label: .secondary))
                }
            }
            .padding(Spacing.large)
            .card()
            .padding(.horizontal, Spacing.medium)
        }
        .frame(maxHeight: .infinity)
    }

    private var answerBar: some View {
        HStack(spacing: Spacing.regular) {
            Spacer()
            Button(AskExplainMock.later) {}.buttonStyle(.kitSecondary)
            Button(AskExplainMock.answer) {}.buttonStyle(.kitPrimary)
        }
        .controlSize(.small)
        .padding(Spacing.medium)
    }

    // MARK: - Chat view

    private func chat(_ feed: AskExplainMock.Feed) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.compact) {
                Button {} label: {
                    Label(AskExplainMock.back, systemImage: "chevron.left").font(.caption)
                }
                .buttonStyle(.kitQuiet)
                .fixedSize()
                Text(AskExplainMock.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.bottom, Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            rows(feed)
            composer(streaming: feed == .busy || feed == .loading)
        }
    }

    private func rows(_ feed: AskExplainMock.Feed) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                switch feed {
                case .queued:
                    status(AskExplainMock.queued, symbol: "hourglass")
                case .loading:
                    status(AskExplainMock.explaining, symbol: "ellipsis")
                case .error:
                    VStack(alignment: .leading, spacing: Spacing.regular) {
                        Label(AskExplainMock.errorLine, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Tone.status("red"))
                        Button(AskExplainMock.retry) {}.buttonStyle(.kitSecondary).controlSize(.small)
                    }
                default:
                    explanation
                    ForEach(AskExplainMock.followUps.prefix(followUpCount(feed)), id: \.question) { turn in
                        owner(turn.question)
                        Text(turn.answer)
                    }
                    if feed == .busy {
                        owner("Which servers count as settings?")
                        Text(AskExplainMock.streamingReply + " ▍")
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

    private func followUpCount(_ feed: AskExplainMock.Feed) -> Int {
        switch feed {
        case .long, .busy: AskExplainMock.followUps.count
        default: 0
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(AskExplainMock.explanation, id: \.self) { Text($0) }
        }
    }

    private func owner(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(Tone.status("blue").opacity(ChipTint.fillOpacity),
                        in: RoundedRectangle(cornerRadius: Radius.bubble))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, mock.narrow ? Spacing.wide : Spacing.hero)
    }

    private func status(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(.secondary)
    }

    private func composer(streaming: Bool) -> some View {
        HStack(spacing: Spacing.compact) {
            Text(AskExplainMock.placeholder).foregroundStyle(.tertiary).lineLimit(1)
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
