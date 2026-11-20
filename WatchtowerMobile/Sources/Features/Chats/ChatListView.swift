import ChatUI
import ChatWire
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

/// The Chats tab (iPhone chat spec §6.1, unified chat spec §6.3): the gate's centred message, or the list. The rows,
/// search and row actions are `ChatUI`'s (`ChatListModel` over the hub's `RelayChatClient`); the gate, the hub
/// switcher and the navigation are the phone's shell.
struct ChatsTabView: View {
    static let navigationTitle = "Chats"
    static let searchPrompt = "Search chats"
    static let pinTitle = "Pin"
    static let unpinTitle = "Unpin"
    static let renameTitle = "Rename"
    static let deleteTitle = "Delete"
    static let renameSave = "Save"
    static let renameCancel = "Cancel"
    /// How long the search waits for typing to pause before it asks the hub.
    static let searchPause: Duration = .milliseconds(300)

    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    private let shot: ChatsShot?
    @State private var renaming: ChatList.Conversation?
    @State private var showsOlder = false
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
            .navigationTitle(Self.navigationTitle)
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
        Group {
            if gate.showsList, center.snapshot.list != nil {
                listScreen(gate: gate, now: now)
            } else {
                // Scrolls, so a long line at a large text size is read whole.
                GeometryReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            switcher(now: now).padding(.horizontal, Spacing.large)
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
                        .accessibilityLabel(ChatsGateModel.newChatLabel)
                }
            }
        }
        .onChange(of: gate, initial: true) { center.setGate(gate, host: inputs(now: now).host) }
    }

    private func listScreen(gate: ChatsGateModel, now: Date) -> some View {
        let model = center.listModel
        let query = center.listQuery
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return List {
            switcher(now: now).macsListRow()
            if let banner = gate.banner {
                lineRow(banner)
            }
            if let notice = center.copyNotice {
                lineRow(notice)
            }
            if let notice = model.notice {
                lineRow(notice)
            }
            // Pinned, Recent and the older fold; with a query the titles that have it, found here even with the hub away.
            let sections = ChatListSections(model.conversations, now: now, query: query)
            ForEach(sections.sections) { section in
                Section {
                    ForEach(section.conversations) { chatRow($0, now: now, editable: gate.allowsRowActions) }
                } header: {
                    SectionHeader(section.title).listRowInsets(Self.headerInsets)
                }
            }
            if searching {
                messageRows(model, query: query, gate: gate, host: ChatsGateInputs.current(env, shot: shot, snapshot: center.snapshot, now: now).host)
            } else {
                olderRows(sections, now: now, editable: gate.allowsRowActions)
            }
        }
        .macsList()
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 0)
        .searchable(
            text: Binding(get: { center.listQuery }, set: { center.listQuery = $0 }),
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Self.searchPrompt
        )
        .task(id: query) {
            // Search asks the hub only while it answers (the client refuses otherwise).
            // The hits already shown for this query stay (the hub keeps a search's record a few minutes).
            guard model.searchResult?.query != RelayChatClient.searchQuery(query) else { return }
            do { try await Task.sleep(for: Self.searchPause) } catch { return }
            await model.search(query)
        }
        .refreshable { await env.refresh(.pull) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.pendingDelete != nil {
                ChatUndoBar { model.undo() }
            }
        }
        .task { model.start() }
        .alert(Self.renameTitle, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(Self.renameTitle, text: $renameText)
            Button(Self.renameSave) {
                if let conversation = renaming { Task { await model.rename(conversation.id, renameText) } }
                renaming = nil
            }
            Button(Self.renameCancel, role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private func olderRows(_ sections: ChatListSections, now: Date, editable: Bool) -> some View {
        if let label = sections.olderLabel {
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
                ForEach(sections.older) { chatRow($0, now: now, editable: editable) }
            }
        }
    }

    /// "In messages": the hub's hits for exactly this query (each drawn by `ChatUI`'s search results view), or why
    /// there are none yet — the hub away, the search running, nothing found.
    @ViewBuilder
    private func messageRows(_ model: ChatListModel, query: String, gate: ChatsGateModel, host: TowerHost) -> some View {
        let asked = RelayChatClient.searchQuery(query)
        if let result = model.searchResult, result.query == asked {
            if !result.hits.isEmpty {
                Section {
                    ForEach(Array(result.hits.enumerated()), id: \.offset) { _, hit in
                        ChatSearchResultsView(search: ChatSearch(query: result.query, hits: [hit])) { hit in
                            env.navigation.chatsPath.append(ChatRoute(id: hit.conversationID, messageID: hit.messageID))
                        }
                        .macsListRow()
                    }
                } header: {
                    SectionHeader(ChatListSections.messagesTitle).listRowInsets(Self.headerInsets)
                }
            }
        } else if !gate.online {
            lineRow(ChatText.searchNeedsHub(host))
        } else {
            lineRow(ChatText.searching(host))
        }
    }

    /// One chat row (`ChatUI`'s); with `editable` (the hub answers) its swipe and long-press actions too.
    @ViewBuilder
    private func chatRow(_ conversation: ChatList.Conversation, now: Date, editable: Bool) -> some View {
        let link = Button { env.navigation.chatsPath.append(ChatRoute(id: conversation.id)) } label: {
            ChatListRow(content: ChatListRowContent(conversation, now: now))
        }
        .buttonStyle(.plain)
        .macsListRow()
        if editable {
            rowActions(link, conversation)
        } else {
            link
        }
    }

    private func rowActions(_ link: some View, _ conversation: ChatList.Conversation) -> some View {
        let model = center.listModel
        let pinTitle = conversation.pinned ? Self.unpinTitle : Self.pinTitle
        return link
            .swipeActions(edge: .leading) {
                Button(pinTitle) { Task { await model.pin(conversation.id) } }
                    .tint(PhoneTone.accent.color)
            }
            .swipeActions(edge: .trailing) {
                Button(Self.deleteTitle, role: .destructive) { model.delete(conversation.id) }
                Button(Self.renameTitle) { startRename(conversation) }
            }
            .contextMenu {
                Button {
                    Task { await model.pin(conversation.id) }
                } label: {
                    Label(pinTitle, systemImage: conversation.pinned ? "pin.slash" : "pin")
                }
                Button { startRename(conversation) } label: { Label(Self.renameTitle, systemImage: "pencil") }
                Button(role: .destructive) { model.delete(conversation.id) } label: {
                    Label(Self.deleteTitle, systemImage: "trash")
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

    /// A section header's list insets: with its own 4 on the sides it lines up with the rows' 16.
    private static let headerInsets = EdgeInsets(top: 0, leading: Spacing.medium, bottom: 0, trailing: Spacing.medium)

    /// The share of the screen a centred message sits in, below the switcher (mockups 1b, 1e–1h).
    private static let messageHeightShare: CGFloat = 0.8

    /// The hub switcher chip, as on the other tabs (#1782), on the screen's own clock: a second `TimelineView` inside a
    /// `List` row kept the list re-laying itself out until the watchdog killed the app (0.29.0).
    private func switcher(now: Date) -> some View {
        HubSwitcherChip(now: now)
    }
}

/// The bar after a Delete (mockup 1j): "Chat deleted · Undo" for `ChatListModel.undoWindow`.
struct ChatUndoBar: View {
    let undo: () -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Text(ChatListModel.deletedLine).font(TypeScale.rowTitle)
            Spacer(minLength: Spacing.regular)
            Button(ChatListModel.undoLabel, action: undo).font(TypeScale.rowEmphasis)
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
