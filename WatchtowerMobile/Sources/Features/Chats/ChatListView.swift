import SwiftUI
import WatchtowerKit
import WatchtowerSync

/// What the screenshot tour shows in place of the live hub: its own center and the gate's other inputs.
struct ChatsShot {
    let center: ChatsCenter
    var heartbeat: HeartbeatPayload?
    var route: HubRoute?
    var grant: DeviceGrant?
    var mac: MacReachability = .online
    var relayUnreachable = false
}

/// The Chats tab (iPhone chat spec §6.1–6.2, mockups 1a–1j): the gate's centred message, or the list with its
/// search, row actions and Undo bar. Reads the hub on screen's `ChatsCenter`; every text comes from
/// `ChatsGateModel`, `ChatListModel`, `ChatSearchModel` and `ChatRowActions`.
struct ChatsTabView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    private let shot: ChatsShot?
    @State private var showsOlder = false
    @State private var renaming: ChatList.Conversation?
    @State private var renameText = ""

    init(shot: ChatsShot? = nil) {
        self.shot = shot
    }

    private var center: ChatsCenter { shot?.center ?? env.chats }

    var body: some View {
        @Bindable var navigation = env.navigation
        NavigationStack(path: $navigation.chatsPath) {
            // A Mac turns asleep by the clock alone, and the ages move with it.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                screen(now: context.date)
            }
            .navigationTitle(ChatListModel.navigationTitle)
            .hubSwitcher()
            .navigationDestination(for: ChatRoute.self) { route in
                ChatConversationView(route: route, center: center, shot: shot)
            }
        }
    }

    private func inputs(now: Date) -> ChatsGateInputs {
        ChatsGateInputs.current(env, shot: shot, snapshot: center.snapshot, now: now)
    }

    @ViewBuilder
    private func screen(now: Date) -> some View {
        let gate = ChatsGateModel(inputs(now: now))
        let host = inputs(now: now).host
        Group {
            if gate.showsList, let list = center.snapshot.list {
                listScreen(list, gate: gate, host: host, now: now)
            } else {
                // Scrolls, so a long line at a large text size is read whole.
                GeometryReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            switcher.padding(.horizontal, Spacing.large)
                            if let notice = center.copyNotice {
                                Text(notice)
                                    .font(TypeScale.meta)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, Spacing.large)
                            }
                            if gate.state == .loading {
                                ChatsLoadingView(line: gate.banner).padding(.horizontal, Spacing.large)
                            } else {
                                ChatsGateMessage(model: gate, act: act)
                                    .frame(minHeight: proxy.size.height * Self.messageHeightShare)
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            if gate.showsNewChat {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { act(.newChat) } label: { Image(systemName: "square.and.pencil") }
                        .disabled(!gate.canCreate)
                        .accessibilityLabel(ChatListModel.newChatLabel)
                }
            }
        }
        .onChange(of: gate.online, initial: true) { center.setOnline(gate.online) }
    }

    private func listScreen(_ list: ChatList, gate: ChatsGateModel, host: TowerHost, now: Date) -> some View {
        let search = center.search
        let actions = center.rowActions
        let model = ChatListModel(list: list, now: now, query: search.query, hidden: actions.hiddenIDs)
        let status = search.status(in: center.snapshot.searches)
        return List {
            switcher.macsListRow()
            if let banner = gate.banner {
                lineRow(banner)
            }
            if let notice = center.copyNotice {
                lineRow(notice)
            }
            if let failure = actions.failure {
                lineRow(failure)
            }
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { chatRow($0, editable: gate.allowsRowActions) }
                } header: {
                    SectionHeader(section.title).listRowInsets(Self.headerInsets)
                }
            }
            if search.query.isEmpty {
                olderRows(model, editable: gate.allowsRowActions)
            } else {
                messageRows(status, hidden: actions.hiddenIDs, host: host, now: now)
            }
        }
        .macsList()
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 0)
        .searchable(
            text: Binding(get: { search.query }, set: { search.setQuery($0) }),
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: ChatListModel.searchPrompt
        )
        .refreshable { await env.refresh(.pull) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if actions.pendingDelete != nil {
                ChatUndoBar { actions.undo() }
            }
        }
        .alert(ChatRowActions.renameSheetTitle, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(ChatRowActions.renameSheetTitle, text: $renameText)
            Button(ChatRowActions.renameSave) {
                if let conversation = renaming { Task { await actions.rename(conversation, to: renameText) } }
                renaming = nil
            }
            Button(ChatRowActions.renameCancel, role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private func olderRows(_ model: ChatListModel, editable: Bool) -> some View {
        if let label = model.olderLabel {
            Button {
                withAnimation { showsOlder.toggle() }
            } label: {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: showsOlder ? "chevron.down" : "chevron.right").font(TypeScale.badge)
                    Text(label).font(TypeScale.meta)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .macsListRow()
            if showsOlder {
                ForEach(model.older) { chatRow($0, editable: editable) }
            }
        }
    }

    @ViewBuilder
    private func messageRows(_ status: ChatSearchModel.Status, hidden: Set<Int64>, host: TowerHost, now: Date) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .offline:
            lineRow(ChatText.searchNeedsHub(host))
        case .searching:
            lineRow(ChatText.searching(host))
        case let .results(hits):
            let rows = ChatHitRow.rows(hits, hidden: hidden, now: now)
            if !rows.isEmpty {
                Section {
                    ForEach(rows) { hit in
                        Button { env.navigation.chatsPath.append(hit.route) } label: {
                            FlatRow(icon: .session(tone: .secondary, isRing: true), title: hit.title, titleLineLimit: 1, insets: EdgeInsets()) {
                                Text(hit.attributedSnippet)
                            } trailing: {
                                Text(hit.age).font(TypeScale.time).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .macsListRow()
                    }
                } header: {
                    SectionHeader(ChatListModel.messagesTitle).listRowInsets(Self.headerInsets)
                }
            }
        case .noAnswer:
            VStack(spacing: Spacing.regular) {
                Text(ChatText.noAnswer(host)).font(TypeScale.meta).foregroundStyle(.secondary)
                Button(ChatsGateModel.retry) { center.search.retry() }
                    .buttonStyle(SecondaryActionStyle())
                    .frame(maxWidth: PhoneMetrics.gateButton)
            }
            .frame(maxWidth: .infinity)
            .macsListRow()
        }
    }

    /// One chat row; with `editable` (the hub answers) its swipe and long-press actions too.
    @ViewBuilder
    private func chatRow(_ row: ChatListModel.Row, editable: Bool) -> some View {
        let link = Button { env.navigation.chatsPath.append(ChatRoute(id: row.id)) } label: {
            ChatRowView(row: row)
        }
        .buttonStyle(.plain)
        .macsListRow()
        if editable {
            rowActions(link, row.conversation)
        } else {
            link
        }
    }

    private func rowActions(_ link: some View, _ conversation: ChatList.Conversation) -> some View {
        let actions = center.rowActions
        let pinTitle = ChatRowActions.pinActionTitle(pinned: conversation.pinned)
        return link
            .swipeActions(edge: .leading) {
                Button(pinTitle) { Task { await actions.togglePin(conversation) } }
                    .tint(PhoneTone.accent.color)
            }
            .swipeActions(edge: .trailing) {
                Button(ChatRowActions.deleteTitle, role: .destructive) { actions.delete(conversation.id) }
                Button(ChatRowActions.renameTitle) { startRename(conversation) }
            }
            .contextMenu {
                Button {
                    Task { await actions.togglePin(conversation) }
                } label: {
                    Label(pinTitle, systemImage: conversation.pinned ? "pin.slash" : "pin")
                }
                Button { startRename(conversation) } label: { Label(ChatRowActions.renameTitle, systemImage: "pencil") }
                Button(role: .destructive) { actions.delete(conversation.id) } label: {
                    Label(ChatRowActions.deleteTitle, systemImage: "trash")
                }
            }
    }

    private func startRename(_ conversation: ChatList.Conversation) {
        renameText = conversation.title
        renaming = conversation
    }

    private func lineRow(_ text: String) -> some View {
        Text(text)
            .font(TypeScale.meta)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .macsListRow()
    }

    private func act(_ action: ChatsGateModel.Action) {
        switch action {
        case .newChat:
            env.navigation.chatsPath.append(.new)
        case .retry:
            Task { await center.retryList() }
        case .switchToRelay:
            guard let hubID = env.activeHubID else { return }
            let row = linking.links.first { $0.hubID == hubID }
            let detail = MacsView.opensDetail(
                account: env.relayAccount, availability: env.relay.availability, row: row, session: env.session(hubID)
            )
            env.navigation.showTowerSettings(hubID: hubID, detail: detail)
        }
    }

    /// The share of the screen a centred message sits in, below the switcher (mockups 1b, 1e–1h).
    private static let messageHeightShare: CGFloat = 0.8

    /// A section header's list insets: with its own 4 on the sides it lines up with the rows' 16.
    private static let headerInsets = EdgeInsets(top: 0, leading: Spacing.medium, bottom: 0, trailing: Spacing.medium)

    /// The hub switcher chip, as on the other tabs (#1782).
    private var switcher: some View {
        TimelineView(.periodic(from: .now, by: 30)) { HubSwitcherChip(now: $0.date) }
    }
}

/// One chat row (mockup 1a): the state dot, the title, the project and the state or last line, and the age.
struct ChatRowView: View {
    let row: ChatListModel.Row

    var body: some View {
        FlatRow(icon: .session(tone: row.tone, isRing: row.isRing), title: row.title, titleLineLimit: 1, insets: EdgeInsets()) {
            HStack(spacing: Spacing.small) {
                if let project = row.project {
                    Image(systemName: "folder").accessibilityHidden(true)
                    Text(project)
                    if !row.detail.isEmpty { Text("·") }
                }
                if !row.detail.isEmpty { Text(row.detail) }
            }
        } trailing: {
            Text(row.age).font(TypeScale.time).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel)
    }
}

/// The bar after a Delete (mockup 1j): "Chat deleted · Undo" for `ChatRowActions.undoWindow`.
struct ChatUndoBar: View {
    let undo: () -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Text(ChatRowActions.undoText).font(TypeScale.rowTitle)
            Spacer(minLength: Spacing.regular)
            Button(ChatRowActions.undoAction, action: undo).font(TypeScale.rowEmphasis)
        }
        .padding(.horizontal, Spacing.large)
        .frame(minHeight: PhoneMetrics.minTouch)
        // Opaque: the rows scroll under it.
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
        .background(PhoneSurface.page, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
                .strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline)
        }
        .padding(.horizontal, Spacing.large)
        .padding(.bottom, Spacing.regular)
    }
}

extension ChatsGateInputs {
    /// The gate's inputs now: the hub on screen's heartbeat, grant, route and reachability, or the shot's.
    @MainActor
    static func current(_ env: AppEnvironment, shot: ChatsShot?, snapshot: ChatsSnapshot, now: Date) -> Self {
        if let shot {
            return Self(
                heartbeat: shot.heartbeat, route: shot.route, grant: shot.grant, refusal: snapshot.refusal, list: snapshot.list,
                mac: shot.mac, relayUnreachable: shot.relayUnreachable
            )
        }
        let session = env.activeSession
        let replica = env.workbenchReplica.snapshot
        return Self(
            heartbeat: replica.heartbeat, route: session.route, grant: replica.grant(for: env.linkedDevice?.deviceID),
            refusal: snapshot.refusal, list: snapshot.list, mac: env.macReachability(now: now),
            relayUnreachable: session.relayUnansweredSince != nil
        )
    }
}
