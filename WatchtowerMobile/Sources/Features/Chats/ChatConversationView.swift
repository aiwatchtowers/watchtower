import PhotosUI
import SwiftUI
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync

/// The conversation screen (iPhone chat spec §6.2–§6.4, mockups 2a–2i, 3a–3c): the feed, the lines over the
/// composer, the composer with its chips, quotes and files, and the sheets. Every text comes from
/// `ChatConversationModel`, `ChatFeedItems`, `ChatComposerModel` and `ChatText`.
struct ChatConversationView: View {
    @Environment(AppEnvironment.self) private var env
    let center: ChatsCenter
    let shot: ChatsShot?
    @State private var model: ChatConversationModel
    @State private var artifact: ChatArtifactContent?
    @State private var sources: [ChatFeed.Source]?
    @State private var quoting: String?
    @State private var attaching = false
    @State private var camera = false
    @State private var library = false
    @State private var files = false
    @State private var photos: [PhotosPickerItem] = []

    init(route: ChatRoute, center: ChatsCenter, shot: ChatsShot? = nil) {
        self.center = center
        self.shot = shot
        _model = State(initialValue: center.conversation(route))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            screen(ChatsGateModel(ChatsGateInputs.current(env, shot: shot, snapshot: center.snapshot, now: context.date)),
                   inputs: ChatsGateInputs.current(env, shot: shot, snapshot: center.snapshot, now: context.date))
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $artifact) { ChatArtifactSheet(artifact: $0, host: host) }
        .sheet(isPresented: Binding(get: { sources != nil }, set: { if !$0 { sources = nil } })) {
            ChatSourcesSheet(sources: sources ?? [])
        }
        .sheet(isPresented: Binding(get: { quoting != nil }, set: { if !$0 { quoting = nil } })) {
            ChatQuotePicker(text: quoting ?? "") { model.addQuote($0) }
        }
        .sheet(isPresented: $attaching) {
            ChatAttachmentMenu { source in
                attaching = false
                switch source {
                case .camera: camera = true
                case .library: library = true
                case .files: files = true
                }
            }
        }
        .fullScreenCover(isPresented: $camera) {
            ChatCameraPicker { data in
                camera = false
                if let data { model.attach(data: data, fileName: Self.photoName) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $library, selection: $photos, maxSelectionCount: 4, matching: .images)
        .onChange(of: photos) { _, items in loadPhotos(items) }
        .fileImporter(isPresented: $files, allowedContentTypes: ChatAttachmentMenu.fileTypes, allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .onDisappear {
            model.disappear()
            if let screen { env.navigation.screenDisappeared(screen) }
        }
    }

    static let photoName = "Photo.jpg"

    private var host: TowerHost {
        ChatsGateInputs.current(env, shot: shot, snapshot: center.snapshot, now: Date()).host
    }

    private var screen: AlertDestination? {
        guard !model.isNew, let hubID = env.activeHubID else { return nil }
        return .chat(hubID: hubID, conversationID: model.conversationID)
    }

    @ViewBuilder
    private func screen(_ gate: ChatsGateModel, inputs: ChatsGateInputs) -> some View {
        let host = inputs.host
        let permissions = inputs.grant?.permissionsAllowed ?? false
        let canAct = gate.allowsRowActions && model.lease == nil
        let items = model.items(permissions: permissions, host: host)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.medium) {
                    ForEach(items) { item in
                        row(item, host: host, canAct: canAct).id(item.id)
                    }
                }
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.regular)
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: model.placeholder == .loading ? .top : .center) {
                if let placeholder = model.placeholder, items.isEmpty {
                    placeholderView(placeholder, host: host).padding(.horizontal, Spacing.large).padding(.vertical, Spacing.regular)
                }
            }
            .onChange(of: model.messages.count) {
                model.followFocus()
                if let focus = model.focusMessageID { proxy.scrollTo("m\(focus)", anchor: .center) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer(gate: gate, inputs: inputs)
        }
        .onAppear {
            model.appear(online: gate.allowsRowActions)
            if let screen { env.navigation.screenAppeared(screen) }
        }
        .onChange(of: gate.allowsRowActions) { _, online in model.setOnline(online) }
        .onChange(of: model.newestCompleteAnswer) { model.markRead() }
        .onChange(of: model.live == nil) { model.markRead() }
    }

    @ViewBuilder
    private func placeholderView(_ placeholder: ChatConversationModel.Placeholder, host: TowerHost) -> some View {
        switch placeholder {
        case .newChat:
            VStack(spacing: Spacing.regular) {
                Text(ChatText.newChatTitle(host)).font(TypeScale.screenTitle)
                Text(ChatConversationModel.newChatLine).font(TypeScale.meta).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        case .loading:
            VStack(alignment: .leading, spacing: Spacing.regular) {
                skeleton(0.5).frame(maxWidth: .infinity, alignment: .trailing)
                skeleton(1)
                skeleton(0.75)
                Text(ChatText.opening(host)).font(TypeScale.meta).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        case .noAnswer:
            VStack(spacing: Spacing.regular) {
                Text(ChatText.noAnswer(host)).font(TypeScale.meta).foregroundStyle(.secondary)
                Button(ChatsGateModel.retry) { model.retryOpen() }.buttonStyle(SecondaryActionStyle()).frame(maxWidth: PhoneMetrics.gateButton)
            }
            .frame(maxWidth: .infinity)
        case .neverLoaded:
            Text(ChatText.neverLoaded(host))
                .font(TypeScale.meta)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func skeleton(_ share: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: Radius.control).fill(Fill.card).frame(width: proxy.size.width * share)
        }
        .frame(height: PhoneMetrics.skeletonBar)
    }

    @ViewBuilder
    private func row(_ item: ChatFeedItem, host: TowerHost, canAct: Bool) -> some View {
        let actions = ChatFeedRowActions(
            toggleSteps: { model.toggleSteps($0) },
            openArtifact: { key in artifact = model.artifact(key) },
            openSources: { sources = $0 },
            regenerate: { model.regenerate($0) },
            selectBranch: { model.selectBranch($0, step: $1) },
            edit: { model.startEdit($0, text: $1) },
            askAbout: { quoting = $0 },
            loadEarlier: { model.loadEarlier() },
            answer: { model.answer($0, $1) }
        )
        switch item {
        case let .earlier(state):
            ChatEarlierRow(state: state, host: host) { model.loadEarlier() }
        case let .owner(owner):
            ChatOwnerBubble(owner: owner, actions: actions)
        case let .answer(answer):
            ChatAnswerView(answer: answer, expanded: model.expandedSteps.contains(answer.message.id), canAct: canAct, actions: actions)
        case let .actions(cards):
            VStack(spacing: Spacing.regular) {
                ForEach(cards) { card in ChatApprovalCard(model: card) { actions.answer(card.action, $0) } }
            }
        }
    }

    // MARK: - The composer

    private func composerLine(gate: ChatsGateModel, inputs: ChatsGateInputs, composer: ChatComposerModel) -> String? {
        if let line = composer.line { return line }
        if let line = model.leaseLine(inputs.host) { return line }
        guard !gate.allowsRowActions else { return nil }
        if inputs.relayUnreachable, inputs.mac.isOnline { return ChatText.relayUnreachableSending }
        if case .asleep = inputs.mac { return ChatText.asleepSending(inputs.host) }
        return ChatText.offlineSending(inputs.host)
    }

    private func composer(gate: ChatsGateModel, inputs: ChatsGateInputs) -> some View {
        let list = center.snapshot.list
        let composer = model.composer(list: list)
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            if let line = composerLine(gate: gate, inputs: inputs, composer: composer) {
                HStack(spacing: Spacing.small) {
                    Text(line).font(TypeScale.meta).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if composer.isEditing {
                        Button { model.cancelEdit() } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel(ChatComposerModel.cancelEditLabel)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            chips(composer, list: list)
            if !model.draft.attachments.isEmpty { attachmentPills }
            HStack(alignment: .bottom, spacing: Spacing.small) {
                Button { attaching = true } label: {
                    Image(systemName: "plus").frame(width: PhoneMetrics.minTouch, height: PhoneMetrics.minTouch)
                }
                .disabled(!composer.canAttach)
                .accessibilityLabel(ChatComposerModel.attachLabel)
                TextField(composer.placeholder, text: Binding(get: { model.draft.text }, set: { model.setText($0) }), axis: .vertical)
                    .font(TypeScale.rowTitle)
                    .lineLimit(1...6)
                    .padding(.vertical, Spacing.regular)
                    .padding(.horizontal, Spacing.medium)
                    .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.pill, style: .continuous))
                sendButton(composer, list: list)
            }
        }
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.compact)
        .background(alignment: .top) { Divider() }
        .background(PhoneSurface.page, ignoresSafeAreaEdges: .bottom)
    }

    private func sendButton(_ composer: ChatComposerModel, list: ChatList?) -> some View {
        Button {
            if composer.showsStop { model.stop() } else { model.send(list: list) }
        } label: {
            Image(systemName: composer.showsStop ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.title)
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    composer.showsStop ? PhoneSurface.page : (composer.canSend ? Color.white : Color.secondary),
                    composer.showsStop ? Color.primary : (composer.canSend ? Color.accentColor : Fill.card)
                )
                .frame(minWidth: PhoneMetrics.minTouch, minHeight: PhoneMetrics.minTouch)
        }
        .buttonStyle(.plain)
        .disabled(composer.showsStop ? !composer.canStop : !composer.canSend)
        .accessibilityLabel(composer.showsStop ? ChatComposerModel.stopLabel : ChatComposerModel.sendLabel)
    }

    @ViewBuilder
    private func chips(_ composer: ChatComposerModel, list: ChatList?) -> some View {
        if !composer.quotes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.small) {
                    ForEach(composer.quotes) { quote in
                        Button { model.removeQuote(quote.id) } label: {
                            Text("❝ \(quote.quote) ✕").lineLimit(1)
                        }
                        .buttonStyle(ChatChipStyle())
                    }
                }
            }
        } else {
            HStack(spacing: Spacing.small) {
                if composer.modelChip.editable {
                    Menu {
                        ForEach(Array(ChatComposerModel.modelOptions(list).enumerated()), id: \.offset) { _, option in
                            Button(option.label) { model.setRouting(option.routing) }
                        }
                    } label: { Text(composer.modelChip.label + " ⌄").modifier(ChatChipLook()) }
                    Menu {
                        Button(ChatComposerModel.noProject) { model.setProject(nil) }
                        ForEach(list?.projects ?? []) { project in Button(project.name) { model.setProject(project.id) } }
                    } label: { Label(composer.projectChip.label + " ⌄", systemImage: "folder").modifier(ChatChipLook()) }
                } else {
                    Text(composer.modelChip.label).modifier(ChatChipLook())
                    Label(composer.projectChip.label, systemImage: "folder").modifier(ChatChipLook())
                }
            }
        }
    }

    private var attachmentPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.small) {
                ForEach(model.draft.attachments) { file in
                    HStack(spacing: Spacing.small) {
                        Image(systemName: file.isImage ? "photo" : "doc")
                        Text(file.name).lineLimit(1)
                        switch file.state {
                        case .uploading: ProgressView().controlSize(.mini)
                        case .failed: Button(ChatsGateModel.retry) { model.retryAttachment(file.id) }
                        case .ready, .uploaded: EmptyView()
                        }
                        Button { model.removeAttachment(file.id) } label: { Image(systemName: "xmark") }
                            .disabled(file.state == .uploading)
                    }
                    .modifier(ChatChipLook())
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if !model.isNew, let conversation = center.snapshot.list?.conversations.first(where: { $0.id == model.conversationID }) {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await center.rowActions.togglePin(conversation) }
                    } label: {
                        Label(ChatRowActions.pinActionTitle(pinned: conversation.pinned), systemImage: conversation.pinned ? "pin.slash" : "pin")
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
    }

    // MARK: - Files

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photos = []
        Task {
            for (index, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                model.attach(data: data, fileName: "Photo \(index + 1).\(ext)")
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                center.drafts.setNotice(ChatSendCoordinator.couldNotSend, conversation: model.conversationID)
                continue
            }
            model.attach(data: data, fileName: url.lastPathComponent)
        }
    }
}

/// A chip over the composer (mockups 2a, 2h, 2i).
struct ChatChipLook: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(TypeScale.pill)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Spacing.small)
            .background(Fill.card, in: Capsule())
    }
}

struct ChatChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ChatChipLook()).opacity(configuration.isPressed ? PhoneOpacity.pressed : 1)
    }
}
