import SwiftUI
import WatchtowerSync

struct SessionRoute: Hashable {
    let id: Int64
}

/// One session (spec §13 B3): the header (title, target, branch, agent and
/// age, the Mac's state), its open asks on top, the report's progress and
/// summary, and the timeline. Opening it asks the Mac for a fresh report.
/// Its asks open their forms. The actions menu stops a live session on the
/// Mac after a confirmation, and Finish asks it to wrap up. "Tell the
/// session…" sends it a line (PROJ-16), on a phone the Mac allowed to type.
struct SessionDetailView: View {
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
                content(detail, now: context.date)
            } else {
                ContentUnavailableView(
                    "Session not found",
                    systemImage: "terminal",
                    description: Text("It was removed on your Mac.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The bar is not an empty strip with a lone "⋯".
            ToolbarItem(placement: .principal) {
                if let title = replica.snapshot.session(viewModel.sessionID)?.title {
                    Text(title).font(.headline).lineLimit(1)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let input = input(now: .now), input.showsBar {
                TellSessionBar(model: input, isSending: env.sessionInputs.inFlight.contains(
                    SessionInputSender.sendKey(viewModel.sessionID)
                )) { text in await send(text) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let actions = actions(now: .now), actions.hasActions {
                    Menu {
                        if actions.showsFinish {
                            Button("Finish", systemImage: "flag.checkered") { finish() }
                        }
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
            SessionActionsModel(
                session: $0, snapshot: replica.snapshot, inFlight: env.sessionStarts.inFlight, now: now,
                showsFinish: input(now: now)?.showsFinish == true
            )
        }
    }

    private func input(now: Date) -> SessionInputModel? {
        replica.snapshot.session(viewModel.sessionID).map {
            SessionInputModel(
                session: $0, snapshot: replica.snapshot,
                grant: replica.snapshot.grant(for: env.linkedDevice?.deviceID),
                typingRequested: env.deviceSettings.typingRequested,
                delivered: env.sessionInputs.delivered[$0.id], now: now
            )
        }
    }

    /// Whether the line was queued (the bar clears its field then).
    private func send(_ text: String) async -> Bool {
        do {
            return try await env.sessionInputs.send(sessionID: viewModel.sessionID, text: text)
        } catch {
            sendError = BoardWriteText.sendError(error)
            return false
        }
    }

    private func finish() {
        let sessionID = viewModel.sessionID
        Task {
            do {
                try await env.sessionInputs.finish(sessionID: sessionID)
            } catch {
                sendError = BoardWriteText.sendError(error)
            }
        }
    }

    private func cancelLine(_ row: PendingAction) {
        Task {
            do {
                try await env.sessionInputs.cancel(row)
            } catch {
                sendError = BoardWriteText.sendError(error)
            }
        }
    }

    private func dismissLine(_ row: PendingAction) {
        do {
            try env.sessionInputs.dismiss(row)
        } catch {
            sendError = BoardWriteText.sendError(error)
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

    /// `now` is the timeline's tick, so a stop row's "Stopping…" turns into
    /// "Waiting for your Mac" when the heartbeat goes stale.
    private func content(_ detail: SessionDetailModel, now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(detail)
                if let actions = actions(now: now) {
                    ForEach(actions.stopRows) { StopRowView(row: $0, onDismiss: dismissStop) }
                }
                if let notice = detail.approvalNotice {
                    ApprovalNoticeView(text: notice)
                }
                if let input = input(now: now) {
                    ForEach(input.lines) { LineRowView(row: $0, onCancel: cancelLine, onDismiss: dismissLine) }
                    if let notice = input.notice {
                        Label(notice, systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44, alignment: .leading)
                    }
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
        .background(Color(.systemBackground))
    }

    private func header(_ detail: SessionDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.title)
                .font(TypeScale.pageTitle)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                SessionDot(tone: detail.state.tone, isRing: detail.state.isRing)
                Text(detail.state.caption)
            }
            .font(.subheadline)
            .foregroundStyle(detail.state.tone.color)
            .accessibilityElement(children: .combine)
            FlowRow { chips(detail) }
        }
    }

    @ViewBuilder
    private func chips(_ detail: SessionDetailModel) -> some View {
        if let target = detail.target {
            NavigationLink(value: BoardTargetRoute(id: target.id)) {
                Pill(text: target.label, tone: .accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Target \(target.label)")
        }
        if let branch = detail.branch {
            Pill(text: branch, style: .neutral, monospaced: true)
                .frame(minHeight: 44)
                .accessibilityLabel("Branch \(branch)")
        }
        Pill(text: detail.agentLine, style: .neutral).frame(minHeight: 44)
    }

    private func timeline(_ detail: SessionDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Timeline")
                .font(TypeScale.sectionHeader)
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
                Button { onDismiss(row.pending) } label: {
                    Text("Dismiss")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.subheadline)
                .accessibilityLabel("Dismiss the failed stop")
            }
        }
        .frame(minHeight: 44)
        .buttonStyle(.borderless)
    }
}

/// The phone never answers a permission prompt (PROJ-16).
private struct ApprovalNoticeView: View {
    let text: String

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "hand.raised.fill").accessibilityHidden(true)
            Text(text).font(TypeScale.rowEmphasis)
            Spacer(minLength: 0)
        }
        .foregroundStyle(PhoneTone.waitingForYou.color)
        .frame(minHeight: 44)
        .card(.waiting)
        .accessibilityElement(children: .combine)
    }
}

/// "Waiting for you" with the session's open asks; a row opens its form.
private struct SessionAsksBox: View {
    let asks: [WaitingCardModel]
    let since: String?

    var body: some View {
        WaitingStack(asks: asks) {
            VStack(spacing: 0) {
                HStack(spacing: Spacing.regular) {
                    SessionDot(tone: .waitingForYou, isRing: false, size: 8)
                    Text("Waiting for you").font(TypeScale.rowEmphasis).foregroundStyle(PhoneTone.waitingForYou.color)
                    Spacer(minLength: Spacing.regular)
                    if let since {
                        Text(since).font(TypeScale.meta).foregroundStyle(.secondary)
                    }
                }
                .padding(RowInsets.flat)
                .accessibilityAddTraits(.isHeader)
                Divider()
            }
        }
    }
}

/// The report: "REPORT · 2 / 7 targets", the segments, the summary and PRs.
private struct SessionReportCard: View {
    let report: SessionReportSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Report")
                    .font(TypeScale.sectionHeader)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(report.progressLabel)
                    .font(TypeScale.time)
                    .foregroundStyle(.secondary)
            }
            if !report.segments.isEmpty {
                segments
            }
            ForEach(report.summary, id: \.self) { line in
                Text(line).font(TypeScale.rowTitle)
            }
            ForEach(report.prLines, id: \.self) { line in
                Text(line)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .card(.plain)
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
                .font(TypeScale.time)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            SessionDot(tone: row.tone, isRing: false, size: 8)
            Text(row.text)
                .font(TypeScale.rowTitle)
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

/// One line the phone sent, until the Mac applied it: how far it got, why
/// it is held (Cancel), or the Mac's refusal (Dismiss).
private struct LineRowView: View {
    let row: SessionInputModel.LineRow
    let onCancel: (PendingAction) -> Void
    let onDismiss: (PendingAction) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text).font(TypeScale.rowTitle).lineLimit(2)
                caption
            }
            Spacer(minLength: 8)
            switch row.state {
            case .waiting:
                EmptyView()
            case .held:
                Button { onCancel(row.pending) } label: {
                    Text("Cancel").frame(minHeight: 44).contentShape(Rectangle())
                }
                .font(.subheadline)
                .accessibilityLabel("Cancel the held message")
            case .failed:
                Button { onDismiss(row.pending) } label: {
                    Text("Dismiss").frame(minHeight: 44).contentShape(Rectangle())
                }
                .font(.subheadline)
                .accessibilityLabel("Dismiss the message")
            }
        }
        .frame(minHeight: 44)
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var caption: some View {
        switch row.state {
        case let .waiting(text), let .held(text):
            Label(text, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case let .failed(text):
            Text(text).font(.caption).foregroundStyle(PhoneTone.red.color)
        }
    }
}

/// "Tell the session…": a line to an idle session (PROJ-16). At a
/// permission prompt it sends nothing and says so.
private struct TellSessionBar: View {
    let model: SessionInputModel
    let isSending: Bool
    let onSend: (String) async -> Bool
    @State private var text = ""

    var body: some View {
        BottomActionBar {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(spacing: Spacing.regular) {
                    TextField("Tell the session…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Message to the session")
                    if model.canSend {
                        Button {
                            Task {
                                if await onSend(text) { text = "" }
                            }
                        } label: {
                            Image(systemName: "arrow.right")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || text.count > SessionInputModel.maxLength)
                        .accessibilityLabel("Send")
                    }
                }
                Text(model.approvalText ?? SessionInputModel.footnote)
                    .font(.caption)
                    .foregroundStyle(model.approvalText == nil ? Color.secondary : PhoneTone.waitingForYou.color)
            }
        }
    }
}
