import SwiftUI
import WatchtowerSync

struct SessionRoute: Hashable {
    let id: Int64
}

/// One session (spec §13 B3): the header (title, target, branch, agent and
/// age, the Mac's state), its open asks on top, the report's progress and
/// summary, and the timeline. Opening it asks the Mac for a fresh report.
/// Its asks open their forms. The actions menu stops a live session on the
/// Mac after a confirmation; Finish comes with session input.
struct SessionDetailView: View {
    /// "Tell the session…" arrives with session input (PROJ-16); until then
    /// the bar is built but not shown.
    static let showsTellBar = false

    @Environment(AppEnvironment.self) private var env
    let replica: WorkbenchReplicaModel
    @State private var viewModel: SessionDetailViewModel
    @State private var confirmingStop = false
    @State private var sendError: String?

    init(replica: WorkbenchReplicaModel, sessionID: Int64, store: ReplicaStore, requester: SessionReportRequester) {
        self.replica = replica
        _viewModel = State(initialValue: SessionDetailViewModel(sessionID: sessionID, store: store, requester: requester))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let detail = SessionDetailModel(
                sessionID: viewModel.sessionID,
                snapshot: replica.snapshot,
                report: viewModel.report,
                timeline: viewModel.timeline,
                now: context.date
            ) {
                content(detail)
            } else {
                ContentUnavailableView(
                    "Session not found",
                    systemImage: "terminal",
                    description: Text("It was removed on your Mac.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if Self.showsTellBar {
                TellSessionBar()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let actions = actions(now: .now), actions.hasActions {
                    Menu {
                        if actions.canStop {
                            Button("Stop", systemImage: "stop.fill", role: .destructive) { confirmingStop = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Session actions")
                }
            }
        }
        .confirmationDialog(SessionStartText.stopConfirm, isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { stop() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
        }
        .task { await viewModel.opened() }
    }

    private func actions(now: Date) -> SessionActionsModel? {
        replica.snapshot.session(viewModel.sessionID).map {
            SessionActionsModel(session: $0, snapshot: replica.snapshot, inFlight: env.sessionStarts.inFlight, now: now)
        }
    }

    private func stop() {
        let sessionID = viewModel.sessionID
        Task {
            do {
                try await env.sessionStarts.stop(sessionID: sessionID)
            } catch {
                sendError = BoardWriteText.sendError(error)
            }
        }
    }

    private func dismissStop(_ row: PendingAction) {
        do {
            try env.sessionStarts.dismiss(row)
        } catch {
            sendError = BoardWriteText.sendError(error)
        }
    }

    private func content(_ detail: SessionDetailModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(detail)
                if let actions = actions(now: .now) {
                    ForEach(actions.stopRows) { StopRowView(row: $0, onDismiss: dismissStop) }
                }
                if let notice = detail.approvalNotice {
                    ApprovalNoticeView(text: notice)
                }
                if !detail.asks.isEmpty {
                    SessionAsksBox(asks: detail.asks, since: detail.asksSince)
                }
                if let report = detail.report {
                    SessionReportCard(report: report)
                }
                timeline(detail)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func header(_ detail: SessionDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                SessionDot(tone: detail.state.tone, isRing: detail.state.isRing)
                if let glyph = detail.state.glyph {
                    Image(systemName: glyph).accessibilityHidden(true)
                }
                Text(detail.state.caption)
            }
            .font(.subheadline)
            .foregroundStyle(detail.state.tone.color)
            .accessibilityElement(children: .combine)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { chips(detail) }
                VStack(alignment: .leading, spacing: 0) { chips(detail) }
            }
        }
    }

    @ViewBuilder
    private func chips(_ detail: SessionDetailModel) -> some View {
        if let target = detail.target {
            NavigationLink(value: BoardTargetRoute(id: target.id)) {
                InfoPill(text: target.label, tint: .accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Target \(target.label)")
        }
        if let branch = detail.branch {
            InfoPill(text: branch, monospaced: true)
                .accessibilityLabel("Branch \(branch)")
        }
        InfoPill(text: detail.agentLine)
    }

    private func timeline(_ detail: SessionDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Timeline")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if let empty = detail.timelineEmptyText {
                Text(empty)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44, alignment: .leading)
            }
            ForEach(detail.timeline) { row in
                if let target = row.targetID {
                    NavigationLink(value: BoardTargetRoute(id: target)) {
                        MilestoneRowView(row: row, opens: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    MilestoneRowView(row: row, opens: false)
                }
            }
            if let more = detail.timelineMoreText {
                Text(more)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The phone's Stop until the Mac applies it, or the Mac's refusal with
/// Dismiss.
private struct StopRowView: View {
    let row: SessionActionsModel.StopRow
    let onDismiss: (PendingAction) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch row.state {
            case let .sending(caption):
                Label("Stop · \(caption)", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case let .failed(message):
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(PhoneTone.red.color)
                Spacer(minLength: 8)
                Button("Dismiss") { onDismiss(row.pending) }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Dismiss the failed stop")
            }
        }
        .frame(minHeight: 44)
        .buttonStyle(.borderless)
    }
}

/// A small rounded label of the header.
private struct InfoPill: View {
    let text: String
    var tint: Color = .secondary
    var monospaced = false

    var body: some View {
        Text(text)
            .font(monospaced ? .caption.monospaced() : .caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// The phone never answers a permission prompt (PROJ-16).
private struct ApprovalNoticeView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").accessibilityHidden(true)
            Text(text).font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(PhoneTone.waitingForYou.color)
        .padding(12)
        .frame(minHeight: 44)
        .background(PhoneTone.waitingForYou.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PhoneTone.waitingForYou.color.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// "Waiting for you" with the session's open asks; a row opens its form.
private struct SessionAsksBox: View {
    let asks: [WaitingCardModel]
    let since: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SessionDot(tone: .waitingForYou, isRing: false, size: 8)
                Text("Waiting for you").font(.subheadline.weight(.semibold))
                    .foregroundStyle(PhoneTone.waitingForYou.color)
                Spacer(minLength: 8)
                if let since {
                    Text(since).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)
            ForEach(asks) { ask in
                Divider()
                NavigationLink(value: AskRoute(id: ask.id)) {
                    HStack(spacing: 12) {
                        Text(ask.kindLabel)
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(ask.tone.color)
                            .frame(width: 56, alignment: .leading)
                        Text(ask.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PhoneTone.waitingForYou.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PhoneTone.waitingForYou.color.opacity(0.5), lineWidth: 1))
    }
}

/// The report: "REPORT · 2 / 7 targets", the segments, the summary and PRs.
private struct SessionReportCard: View {
    let report: SessionReportSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Report")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(report.progressLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if !report.segments.isEmpty {
                segments
            }
            ForEach(report.summary, id: \.self) { line in
                Text(line).font(.subheadline)
            }
            ForEach(report.prLines, id: \.self) { line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var segments: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let totalWeight = CGFloat(report.segments.reduce(0) { $0 + $1.weight })
            let width = max(0, proxy.size.width - spacing * CGFloat(report.segments.count - 1))
            HStack(spacing: spacing) {
                ForEach(report.segments) { segment in
                    Capsule()
                        .fill(segment.tone == .secondary ? Color.secondary.opacity(0.3) : segment.tone.color)
                        .frame(width: width * CGFloat(segment.weight) / max(1, totalWeight))
                        .accessibilityLabel(segment.label)
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(report.accessibilityLabel)
    }
}

/// One timeline row; `opens` adds the chevron of a target milestone.
private struct MilestoneRowView: View {
    let row: MilestoneRow
    let opens: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.time)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            SessionDot(tone: row.tone, isRing: false, size: 8)
            Text(row.text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

/// "Tell the session…": a line to an idle session (PROJ-16). Built ahead of
/// session input and not shown until then (`showsTellBar`).
private struct TellSessionBar: View {
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Tell the session…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Message to the session")
                Button {} label: {
                    Image(systemName: "arrow.right")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .accessibilityLabel("Send")
            }
            Text("Delivered when the agent is idle · opt-in in Settings")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
