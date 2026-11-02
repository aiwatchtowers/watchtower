import SwiftUI
import DesignKit
import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

/// Proposed change only: a single caption line. No production view is changed.
struct WorkchatLiveShotModel: Equatable {
    struct Agent: Equatable, Identifiable {
        let id: String
        let task: String
        let action: String
        let elapsed: String
    }

    let text: String
    let symbol: String
    let elapsed: String
    let agentsBadge: String?
    let agents: [Agent]
    let retry: String?
    let warning: Bool
    let isEmpty: Bool
    let isLoading: Bool

    var placeholder: String { "Message the agent… (/ for commands)" }
    var ownerMessage: String? { isEmpty ? nil : "Show what the model is doing while I wait." }
    var agentMessage: String? { isEmpty || isLoading ? nil : "I’m checking the activity events and the subagent lifecycle.\n\n"
                + "The tool summaries are available in the transcript. I’ll keep them in the live status line "
                + "so the conversation stays readable." }
    var popoverTitle: String { "Running agents · \(agents.count)" }
    var agentsHelp: String { agentsBadge == "?" ? "Agent status unavailable" : "Show running agents" }
    var unknownMessage: String { "Agent status unavailable" }
    var composerSymbol: String { isEmpty ? "arrow.up" : "stop.fill" }

    static let samples = [
        Agent(id: "parser", task: "Check Codex event formats", action: "Reading rollout fixtures", elapsed: "1:24"),
        Agent(id: "review", task: "Review feed contracts", action: "Searching FEED-03 guards", elapsed: "0:48"),
        Agent(id: "tests", task: "Check activity presentation", action: "Running presenter tests", elapsed: "0:32")
    ]
    static let empty = Self(
        text: "",
        symbol: "",
        elapsed: "",
        agentsBadge: nil,
        agents: [],
        retry: nil,
        warning: false,
        isEmpty: true,
        isLoading: false
    )
    static let loading = Self(
        text: "Loading activity…",
        symbol: "ellipsis",
        elapsed: "0:02",
        agentsBadge: nil,
        agents: [],
        retry: nil,
        warning: false,
        isEmpty: false,
        isLoading: true
    )
    static let thinking = Self(
        text: "Last · Read SessionFeed.swift",
        symbol: "doc.text",
        elapsed: "0:18",
        agentsBadge: nil,
        agents: [],
        retry: nil,
        warning: false,
        isEmpty: false,
        isLoading: false
    )
    static let busy = Self(
        text: "Running tests · go test ./internal/sessionfeed",
        symbol: "terminal",
        elapsed: "0:12",
        agentsBadge: "3",
        agents: samples,
        retry: nil,
        warning: false,
        isEmpty: false,
        isLoading: false
    )
    static let error = Self(
        text: "Activity unavailable",
        symbol: "exclamationmark.circle",
        elapsed: "",
        agentsBadge: "?",
        agents: [],
        retry: "Retry",
        warning: true,
        isEmpty: false,
        isLoading: false
    )
    static let stale = Self(
        text: "Activity out of date · 18s ago",
        symbol: "clock",
        elapsed: "",
        agentsBadge: "?",
        agents: [],
        retry: "Retry",
        warning: true,
        isEmpty: false,
        isLoading: false
    )
    static let unknownAgents = Self(
        text: "Working…",
        symbol: "ellipsis",
        elapsed: "0:18",
        agentsBadge: "?",
        agents: [],
        retry: nil,
        warning: false,
        isEmpty: false,
        isLoading: false
    )
    static let overflow = Self(text: busy.text, symbol: busy.symbol, elapsed: busy.elapsed, agentsBadge: "5", agents: samples + [
        Agent(id: "docs", task: "Check user guide", action: "Reading workchat.md", elapsed: "0:21"),
        Agent(id: "design", task: "Compare snapshots", action: "Inspecting narrow layout", elapsed: "0:15")
    ], retry: nil, warning: false, isEmpty: false, isLoading: false)
}

@MainActor
struct WorkchatLiveProposalShot: View {
    let model: WorkchatLiveShotModel
    var narrow = false
    var agentsOpen = false
    var usesLiveImplementation = false
    private let fixtureNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func seconds(_ text: String) -> TimeInterval {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : 0
    }
    private var actualSnapshot: SessionFeedLive? {
        if model.isEmpty || model.isLoading || model == .error { return nil }
        let agents = model.agents.map {
            SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: $0.id, type: "Codex", description: $0.task, status: "running"),
                             startedAt: fixtureNow - seconds($0.elapsed), action: SessionLiveAction(tool: "Read", summary: $0.action), canOpen: true)
        }
        let current = model == .busy || model == .overflow
            ? SessionLiveAction(tool: "Bash", summary: model.text, startedAt: fixtureNow - 12) : nil
        return SessionFeedLive(observedAt: model == .stale ? fixtureNow - 18 : fixtureNow,
                               turnAt: fixtureNow - 18,
                               current: current,
                               latest: model == .thinking ? SessionLiveAction(tool: "Read", summary: "Read SessionFeed.swift") : nil,
                               agents: agents, agentsState: model.agentsBadge == "?" ? "unknown" : "known")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.large) {
                if let owner = model.ownerMessage {
                    Text(owner)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.compact)
                        .background(Tone.status("blue").opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.container))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let agent = model.agentMessage {
                    Text(agent).frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: Spacing.large)
            }
            .padding(Spacing.large)
            statusLine
            composer
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailBackground()
        .overlay(alignment: .bottomTrailing) {
            if agentsOpen {
                Group {
                    if usesLiveImplementation {
                        WorkchatRunningAgentsPicker(snapshot: actualSnapshot, error: nil, now: fixtureNow) { _ in }
                            .background(Surface.window, in: RoundedRectangle(cornerRadius: Radius.container))
                            .overlay(RoundedRectangle(cornerRadius: Radius.container)
                                .strokeBorder(.quaternary, lineWidth: Stroke.hairline))
                    } else { agentsPopover }
                }
                    .frame(width: usesLiveImplementation ? PaneWidth.sideListMax + Spacing.wide : (narrow ? 300 : 340))
                    .padding(.trailing, Spacing.large)
                    .padding(.bottom, Spacing.hero * 2)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if usesLiveImplementation {
            WorkchatLiveLine(snapshot: actualSnapshot, error: model == .error ? "Activity unavailable" : nil,
                             loaded: !model.isLoading, working: !model.isEmpty, stateAt: fixtureNow - 2,
                             onRetry: {}, onOpenAgent: { _ in }, referenceDate: fixtureNow)
        } else {
        HStack(spacing: Spacing.compact) {
            if !model.text.isEmpty {
                Image(systemName: model.symbol).frame(width: IconSize.header)
                Text(model.text).lineLimit(1).truncationMode(.middle)
                if let retry = model.retry { Button(retry) {}.buttonStyle(.kitQuiet) }
                Spacer(minLength: Spacing.compact)
                if let badge = model.agentsBadge {
                    Button {} label: {
                        HStack(spacing: Spacing.small) {
                            Image(systemName: "person.2")
                            Text(badge).monospacedDigit()
                        }
                    }
                    .buttonStyle(.kitQuiet)
                    .help(model.agentsHelp)
                }
                if !model.elapsed.isEmpty { Text(model.elapsed).monospacedDigit() }
            } else {
                Text(verbatim: " ")
            }
        }
        .font(.caption)
        .foregroundStyle(model.warning ? Tone.warning : .secondary)
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "paperclip").foregroundStyle(.secondary)
            Text(model.placeholder).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: Spacing.compact)
            Image(systemName: model.composerSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tone.status("blue"))
                .frame(width: IconSize.composerLarge, height: IconSize.composerLarge)
        }
        .padding(Spacing.cozy)
        .background(Surface.text, in: RoundedRectangle(cornerRadius: Radius.control))
        .padding(.horizontal, Spacing.large)
        .padding(.bottom, Spacing.large)
    }

    private var agentsPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(model.popoverTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    ForEach(model.agents) { agent in
                        HStack(alignment: .top, spacing: Spacing.regular) {
                            VStack(alignment: .leading, spacing: Spacing.small) {
                                Text(agent.task).font(.callout)
                                Text(agent.action).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Spacing.small)
                            Text(agent.elapsed).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(model.agents.count), 3) * (ListLayout.rowMinHeight * 2))
        }
        .padding(Spacing.large)
        .background(Surface.window, in: RoundedRectangle(cornerRadius: Radius.container))
        .overlay(RoundedRectangle(cornerRadius: Radius.container).strokeBorder(.quaternary, lineWidth: Stroke.hairline))
    }
}

@MainActor
final class WorkchatLiveProposalCopyTests: XCTestCase {
    func testAllVisibleStateCopy() {
        let models: [WorkchatLiveShotModel] = [.empty, .loading, .thinking, .busy, .error, .stale, .unknownAgents, .overflow]
        XCTAssertEqual(models.map(\.text), [
            "",
            "Loading activity…",
            "Last · Read SessionFeed.swift",
            "Running tests · go test ./internal/sessionfeed",
            "Activity unavailable",
            "Activity out of date · 18s ago",
            "Working…",
            "Running tests · go test ./internal/sessionfeed"
        ])
        XCTAssertEqual(models.map(\.elapsed), ["", "0:02", "0:18", "0:12", "", "", "0:18", "0:12"])
        XCTAssertEqual(models.map(\.agentsBadge), [nil, nil, nil, "3", "?", "?", "?", "5"])
        XCTAssertEqual(models.map(\.retry), [nil, nil, nil, nil, "Retry", "Retry", nil, nil])
        XCTAssertNil(WorkchatLiveShotModel.empty.ownerMessage)
        XCTAssertNil(WorkchatLiveShotModel.empty.agentMessage)
        XCTAssertNil(WorkchatLiveShotModel.loading.agentMessage)
        XCTAssertEqual(WorkchatLiveShotModel.empty.composerSymbol, "arrow.up")
        for model in models {
            XCTAssertEqual(model.placeholder, "Message the agent… (/ for commands)")
            XCTAssertEqual(model.unknownMessage, "Agent status unavailable")
            XCTAssertEqual(model.agentsHelp, model.agentsBadge == "?" ? "Agent status unavailable" : "Show running agents")
            if !model.isEmpty { XCTAssertEqual(model.ownerMessage, "Show what the model is doing while I wait.") }
            if !model.isEmpty && !model.isLoading {
                XCTAssertEqual(model.agentMessage, "I’m checking the activity events and the subagent lifecycle.\n\n"
                + "The tool summaries are available in the transcript. I’ll keep them in the live status line "
                + "so the conversation stays readable.")
            }
        }
        XCTAssertEqual(WorkchatLiveShotModel.busy.popoverTitle, "Running agents · 3")
        XCTAssertEqual(WorkchatLiveShotModel.overflow.popoverTitle, "Running agents · 5")
        XCTAssertEqual(WorkchatLiveShotModel.overflow.agents.map(\.task), [
            "Check Codex event formats",
            "Review feed contracts",
            "Check activity presentation",
            "Check user guide",
            "Compare snapshots"
        ])
        XCTAssertEqual(WorkchatLiveShotModel.overflow.agents.map(\.action), [
            "Reading rollout fixtures",
            "Searching FEED-03 guards",
            "Running presenter tests",
            "Reading workchat.md",
            "Inspecting narrow layout"
        ])
        XCTAssertEqual(WorkchatLiveShotModel.overflow.agents.map(\.elapsed), ["1:24", "0:48", "0:32", "0:21", "0:15"])
    }
}
