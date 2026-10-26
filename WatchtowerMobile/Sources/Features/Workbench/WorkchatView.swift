import SwiftUI
import WatchtowerKit
import WatchtowerSync

struct SessionRoute: Hashable {
    let id: Int64
}

/// One session, as its chat (spec §5.3, §5.4; mockups 3, 4, 8): the header
/// (workbench, title, one state line that counts while the agent works),
/// the dialog without tools, then the phone's own lines on their way, the
/// permission card and the session's open asks at the foot of the feed,
/// and the composer pinned under it. A Claude session takes a line while
/// it works (PROJ-16 amended); a Codex one when it stops. Opening the
/// screen asks the Mac for the chat (FEED-05) until it goes away. The
/// actions menu stops, finishes or interrupts the session and opens its
/// report and board target.
struct WorkchatView: View {
    static let screen = ChatScreen.session

    @Environment(AppEnvironment.self) private var env
    let replica: WorkbenchReplicaModel
    @State private var chat: SessionChatViewModel
    @State private var draft = ""
    @State private var confirmingStop = false
    /// The Bash card whose Allow waits for the confirmation.
    @State private var confirmingAllow: PermissionCardModel?
    @State private var sendError: String?
    @State private var showsReport = false
    @State private var openTarget: BoardTargetRoute?
    @State private var openAsk: AskRoute?
    @State private var openSubagent: SessionChatRoute?

    init(replica: WorkbenchReplicaModel, sessionID: Int64, store: ReplicaStore, requester: SessionChatRequester) {
        self.replica = replica
        _chat = State(initialValue: Self.chatModel(sessionID: sessionID, store: store, requester: requester))
    }

    /// The session's main chat: the workchat never shows a subagent's.
    static func chatModel(sessionID: Int64, store: ReplicaStore, requester: SessionChatRequester) -> SessionChatViewModel {
        SessionChatViewModel(sessionID: sessionID, agentID: nil, store: store, requester: requester)
    }

    private var sessionID: Int64 { chat.sessionID }

    var body: some View {
        let session = replica.snapshot.session(sessionID)
        let model = session.map { workchat($0, now: .now) }
        Group {
            if let session, let model {
                content(session, model)
            } else {
                ContentUnavailableView("Session not found", systemImage: "terminal", description: Text("It was removed on your Mac."))
            }
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let model { composer(model.composer) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let session { menu(session, targetID: model?.targetID) }
            }
        }
        .navigationDestination(isPresented: $showsReport) {
            SessionReportView(replica: replica, sessionID: sessionID, store: env.store, requester: env.reportRequests)
        }
        .navigationDestination(item: $openTarget) { route in
            BoardTargetDetailView(replica: replica, writer: env.boardWriter, targetID: route.id)
        }
        .navigationDestination(item: $openAsk) { route in
            AskView(replica: replica, drafts: env.askDrafts, answerer: env.askAnswerer, askID: route.id)
        }
        .navigationDestination(item: $openSubagent) { route in
            SessionChatView(replica: replica, route: route, store: env.store, requester: env.chatRequests)
        }
        .confirmationDialog(SessionStartText.stopConfirm, isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { stop() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            confirmingAllow?.allowConfirmTitle ?? "",
            isPresented: Binding(get: { confirmingAllow != nil }, set: { if !$0 { confirmingAllow = nil } }),
            titleVisibility: .visible,
            presenting: confirmingAllow
        ) { card in
            Button(PermissionCardModel.allowLabel) { answer(card, .allow) }
            Button("Cancel", role: .cancel) {}
        } message: { card in
            Text(card.summary).monospaced()
        }
        .alert("Couldn't send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
        }
        .onChange(of: lines, initial: true) { _, rows in chat.noteOutgoing(rows.compactMap(SessionChatViewModel.Outgoing.init)) }
        .onAppear { chat.appeared() }
        .onDisappear { chat.disappeared() }
    }

    // MARK: - Models

    private var grant: DeviceGrant? { replica.snapshot.grant(for: env.linkedDevice?.deviceID) }

    private var permissions: PermissionAccess {
        PermissionAccess(
            grant: grant,
            requested: env.deviceSettings.permissionsRequested,
            inFlight: env.sessionInputs.inFlight,
            sentRequestID: env.sessionInputs.answered[sessionID]
        )
    }

    private func input(_ session: TerminalSessionState, now: Date) -> SessionInputModel {
        SessionInputModel(
            session: session, snapshot: replica.snapshot, grant: grant,
            typingRequested: env.deviceSettings.typingRequested,
            delivered: env.sessionInputs.delivered[session.id], now: now,
            answersPermission: PermissionCardModel.answerable(session, in: replica.snapshot, access: permissions)
        )
    }

    private func workchat(_ session: TerminalSessionState, now: Date) -> WorkchatModel {
        WorkchatModel(
            session: session, chat: chat.chat, snapshot: replica.snapshot, input: input(session, now: now),
            permission: PermissionCardModel.card(for: session, in: replica.snapshot, access: permissions, now: now),
            macOnline: MacStatus(heartbeat: replica.snapshot.heartbeat, now: now).isOnline, now: now,
            sentRequestID: permissions.sentRequestID
        )
    }

    private func actions(_ session: TerminalSessionState, now: Date) -> SessionActionsModel {
        SessionActionsModel(
            session: session, snapshot: replica.snapshot, inFlight: env.sessionStarts.inFlight.union(env.sessionInputs.inFlight),
            now: now, showsFinish: input(session, now: now).showsFinish, grant: grant,
            typingRequested: env.deviceSettings.typingRequested
        )
    }

    /// The outbox rows of this session's lines.
    private var lines: [SessionInputModel.LineRow] {
        replica.snapshot.session(sessionID).map { input($0, now: .now).lines } ?? []
    }

    // MARK: - Layout

    private func content(_ session: TerminalSessionState, _ model: WorkchatModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(session, model)
            feed(session, model)
        }
    }

    private func header(_ session: TerminalSessionState, _ model: WorkchatModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            if !model.workbenchName.isEmpty {
                Text(model.workbenchName).font(TypeScale.meta).foregroundStyle(.secondary)
            }
            Text(model.title)
                .font(TypeScale.pageTitle)
                .accessibilityAddTraits(.isHeader)
            // Ticks every second; the rest of the screen follows the replica.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let asOf = MacStatus(heartbeat: replica.snapshot.heartbeat, now: context.date).isOnline
                    ? nil : replica.snapshot.heartbeat?.updatedAt
                StateLine(model: WorkchatModel.stateLine(session, asOf: asOf, now: context.date))
            }
        }
        .padding(.horizontal, Spacing.large)
        .padding(.bottom, Spacing.regular)
    }

    private func feed(_ session: TerminalSessionState, _ model: WorkchatModel) -> some View {
        let lines = input(session, now: .now).lines
        let actions = actions(session, now: .now)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.medium) {
                if let earlier = chat.earlierText {
                    ChatBubble(role: .watchtower, text: earlier)
                }
                dialog(model, hasOwnLines: !lines.isEmpty)
                ForEach(chat.sentLines) { line in
                    ChatBubble(role: .owner, text: line.text, caption: env.sessionInputs.lineDeliveries[line.id]?.caption)
                }
                ForEach(lines) { PendingLineView(row: $0, onCancel: cancelLine, onDismiss: dismissLine) }
                ForEach(actions.stopRows + actions.interruptRows) { StopRowView(row: $0, onDismiss: dismissStop) }
                ForEach(model.answerRows) { AnswerRowView(row: $0, onDismiss: dismissLine) }
                if let notice = model.answerNotice {
                    ChatBubble(role: .watchtower, text: notice)
                }
                if let card = model.permission {
                    permissionCard(card)
                }
                ForEach(model.inlineAsks) { inlineAsk($0, model) }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.regular)
        }
        .defaultScrollAnchor(.bottom)
    }

    /// The chat's entries, or why there are none yet.
    @ViewBuilder
    private func dialog(_ model: WorkchatModel, hasOwnLines: Bool) -> some View {
        if chat.chat == nil {
            Group {
                if chat.waitingForKeys {
                    Text("Unlock this iPhone to see the chat.")
                } else if chat.waitingTooLong {
                    Text(SessionChatText.tooLong)
                } else {
                    Label(SessionChatText.asking, systemImage: "ellipsis.bubble")
                }
            }
            .font(TypeScale.meta)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.large)
        } else if model.entries.isEmpty, !hasOwnLines, chat.sentLines.isEmpty {
            ChatBubble(role: .watchtower, text: "No messages yet")
        }
        ForEach(model.entries) { entry in
            WorkchatEntryRow(entry: entry, sessionID: sessionID) { openSubagent = $0 }
        }
    }

    @ViewBuilder
    private func permissionCard(_ card: PermissionCardModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            InlinePermissionCard(
                toolName: card.tool,
                summary: card.summary,
                allowBlockedNote: card.allowBlock?.note,
                isAnswering: !card.canAnswer,
                onAllow: {
                    if card.confirmsAllow {
                        confirmingAllow = card
                    } else {
                        answer(card, .allow)
                    }
                },
                onDeny: { answer(card, .deny) }
            )
            if let hint = card.hint {
                Text(hint.text).font(TypeScale.meta).foregroundStyle(.secondary)
                if hint == .turnOn {
                    Button("Turn On") { Task { await env.deviceSettings.setPermissionsRequested(true) } }
                        .buttonStyle(SecondaryActionStyle())
                }
                if let error = env.deviceSettings.permissionsError {
                    Text(error).font(TypeScale.meta).foregroundStyle(PhoneTone.red.color)
                }
            }
        }
    }

    @ViewBuilder
    private func inlineAsk(_ card: WaitingCardModel, _ model: WorkchatModel) -> some View {
        if case let .ask(askID) = card.destination {
            InlineAskCard(
                askID: askID,
                kind: card.kindLabel.lowercased(),
                title: card.title,
                options: model.askOptions[askID] ?? [],
                isAnswering: env.askAnswerer.isSending(askID) || isAnswerPending(askID),
                onPick: { pick(askID, $0) },
                onOpen: { openAsk = AskRoute(id: askID) }
            )
        }
    }

    @ViewBuilder
    private func composer(_ state: ComposerState) -> some View {
        if case let .hidden(hint) = state {
            if let hint {
                TypingHintBar(hint: hint, error: env.deviceSettings.typingError) {
                    Task { await env.deviceSettings.setTypingRequested(true) }
                }
            }
        } else if let bar = state.bar {
            WorkchatComposerBar(
                text: $draft,
                mode: bar.mode,
                isSending: env.sessionInputs.inFlight.contains(SessionInputSender.sendKey(sessionID)),
                note: bar.note
            ) { send() }
        }
    }

    private func menu(_ session: TerminalSessionState, targetID: Int64?) -> some View {
        Menu {
            ForEach(WorkchatModel.menu(actions: actions(session, now: .now), targetID: targetID), id: \.self) { item in
                Button(item.title, systemImage: item.systemImage, role: item == .stop ? .destructive : nil) { run(item) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").frame(minWidth: PhoneMetrics.minTouch, minHeight: PhoneMetrics.minTouch)
        }
        .accessibilityLabel("Session actions")
    }

    // MARK: - Actions

    private func run(_ item: WorkchatMenuItem) {
        switch item {
        case .stop: confirmingStop = true
        case .finish: perform { try await env.sessionInputs.finish(sessionID: sessionID) }
        case .interrupt: perform { try await env.sessionInputs.interrupt(sessionID: sessionID) }
        case .report: showsReport = true
        case let .openTarget(id): openTarget = BoardTargetRoute(id: id)
        }
    }

    private func send() {
        let text = draft
        Task {
            do {
                if try await env.sessionInputs.send(sessionID: sessionID, text: text), draft == text {
                    draft = ""
                }
            } catch {
                sendError = BoardWriteText.sendError(error)
            }
        }
    }

    /// A one-tap answer: the pick goes into the ask's draft and is sent as
    /// the full form would send it.
    private func pick(_ askID: Int64, _ option: InlineAskOption) {
        guard let ask = replica.snapshot.asks.first(where: { $0.id == askID }), let quick = ask.quick else { return }
        env.askDrafts.update(askID) { $0.picks[quick.questionID] = AskQuestionPick(labels: [option.label]) }
        perform { try await env.askAnswerer.send(ask) }
    }

    /// An answer to the ask still waits in the outbox.
    private func isAnswerPending(_ askID: Int64) -> Bool {
        replica.snapshot.pending.contains {
            $0.action.kind == .askAnswer && $0.entityRecordName == AskAnswerer.recordName(askID) && $0.state == .pending
        }
    }

    /// Allow once (after the Bash confirmation) or Deny.
    private func answer(_ card: PermissionCardModel, _ behavior: PermissionAnswerParams.Behavior) {
        perform { try await env.sessionInputs.answer(sessionID: card.sessionID, requestID: card.requestID, behavior: behavior) }
    }

    private func stop() {
        perform { try await env.sessionStarts.stop(sessionID: sessionID) }
    }

    private func cancelLine(_ row: PendingAction) {
        perform { try await env.sessionInputs.cancel(row) }
    }

    private func dismissLine(_ row: PendingAction) {
        do {
            try env.sessionInputs.dismiss(row)
        } catch {
            sendError = BoardWriteText.sendError(error)
        }
    }

    private func dismissStop(_ row: PendingAction) {
        do {
            try env.sessionStarts.dismiss(row)
        } catch {
            sendError = BoardWriteText.sendError(error)
        }
    }

    /// Runs one outbox write; its failure is the alert.
    private func perform(_ write: @escaping () async throws -> some Any) {
        Task {
            do {
                _ = try await write()
            } catch {
                sendError = BoardWriteText.sendError(error)
            }
        }
    }
}

/// One entry of the session's chat in the workchat's bubbles (mockup 3):
/// the owner's lines and ask answers right, the agent's text left, the
/// brief and Watchtower's lines as captions, a subagent as a row that opens
/// its own chat.
struct WorkchatEntryRow: View {
    let entry: SessionChat.Entry
    let sessionID: Int64
    let onOpenSubagent: (SessionChatRoute) -> Void
    @State private var briefOpen = false

    var body: some View {
        switch entry.kind {
        case .owner:
            ChatBubble(role: .owner, text: entry.text)
        case .askAnswer:
            ChatBubble(role: .owner, text: entry.text, caption: Self.askCaption(entry.askID))
        case .watchtower:
            ChatBubble(role: .watchtower, text: entry.text)
        case .agent:
            ChatBubble(role: .agent, text: entry.text)
        case .brief:
            brief
        case .separator:
            ChatBubble(role: .watchtower, text: "New conversation")
        case .subagent:
            if let subagent = entry.subagent {
                let route = SessionChatEntryRow.route(for: subagent, sessionID: sessionID)
                ChatBubble(role: .subagent, text: Self.subagentText(subagent), onTap: route.map { route in { onOpenSubagent(route) } })
            }
        default:
            EmptyView()
        }
    }

    private var brief: some View {
        VStack(spacing: Spacing.small) {
            Button {
                briefOpen.toggle()
            } label: {
                Label(Self.briefLabel(entry.title), systemImage: briefOpen ? "chevron.down" : "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(briefOpen ? "Hides the brief" : "Shows the brief the session got")
            if briefOpen {
                ChatMarkdown(text: entry.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    static func askCaption(_ askID: Int64?) -> String {
        askID.map { "Ask #\($0) · via Watchtower" } ?? "Ask · via Watchtower"
    }

    static func briefLabel(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "Brief" }
        return "Brief · \(title)"
    }

    /// "Explore · Find the archive view · finished".
    static func subagentText(_ subagent: SessionChat.Entry.Subagent) -> String {
        [subagent.type.isEmpty ? "Subagent" : subagent.type, subagent.description, SessionChatEntryRow.statusText(subagent.status).lowercased()]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// A line the phone sent that the Mac has not applied: its bubble dimmed,
/// how far it got (or why it is held, with Cancel), or the Mac's refusal
/// with Dismiss.
private struct PendingLineView: View {
    let row: SessionInputModel.LineRow
    let onCancel: (PendingAction) -> Void
    let onDismiss: (PendingAction) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.small) {
            switch row.state {
            case let .waiting(caption):
                ChatBubble(role: .owner, text: row.text, caption: caption, isPending: true)
            case let .held(caption):
                ChatBubble(role: .owner, text: row.text, caption: caption, isPending: true)
                button("Cancel", label: "Cancel the queued message") { onCancel(row.pending) }
            case let .failed(message):
                ChatBubble(role: .owner, text: row.text, isPending: true)
                Text(message).font(.caption2).foregroundStyle(PhoneTone.red.color)
                button("Dismiss", label: "Dismiss the message") { onDismiss(row.pending) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func button(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(minHeight: PhoneMetrics.minTouch).contentShape(Rectangle())
        }
        .font(TypeScale.meta)
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

/// The phone's Stop (or Interrupt) until the Mac applies it, or the Mac's
/// refusal with Dismiss.
private struct StopRowView: View {
    let row: SessionActionsModel.StopRow
    let onDismiss: (PendingAction) -> Void

    var body: some View {
        switch row.state {
        case let .sending(caption):
            ChatBubble(role: .watchtower, text: "\(row.title) · \(caption)")
        case let .failed(message):
            FailedNotice(message: message, label: "Dismiss the failed \(row.title.lowercased())") { onDismiss(row.pending) }
        }
    }
}

/// One answer the phone sent to a prompt: how far it got, or the Mac's
/// refusal (e.g. "Answered on the Mac") with Dismiss.
private struct AnswerRowView: View {
    let row: PermissionAnswerRow
    let onDismiss: (PendingAction) -> Void

    var body: some View {
        switch row.state {
        case let .waiting(caption):
            ChatBubble(role: .watchtower, text: caption)
        case let .failed(message):
            FailedNotice(message: message, label: "Dismiss the answer") { onDismiss(row.pending) }
        }
    }
}

/// A refusal from the Mac at the foot of the feed, with Dismiss.
private struct FailedNotice: View {
    let message: String
    let label: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(message).font(TypeScale.meta).foregroundStyle(PhoneTone.red.color)
            Spacer(minLength: Spacing.regular)
            Button(action: onDismiss) {
                Text("Dismiss").frame(minHeight: PhoneMetrics.minTouch).contentShape(Rectangle())
            }
            .font(TypeScale.meta)
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
        }
    }
}

/// Why the composer is missing (board #515), with Turn On when the phone's
/// own toggle is off — the same request as Settings' "Type into sessions".
private struct TypingHintBar: View {
    let hint: SessionInputModel.TypingHint
    let error: String?
    let onTurnOn: () -> Void

    var body: some View {
        BottomActionBar {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(spacing: Spacing.regular) {
                    Label(hint.text, systemImage: "keyboard")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if hint == .turnOn {
                        Button("Turn On", action: onTurnOn)
                            .buttonStyle(.bordered)
                            .frame(minHeight: PhoneMetrics.minTouch)
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(PhoneTone.red.color)
                }
            }
        }
    }
}
