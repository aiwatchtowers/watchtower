import ChatUI
import ChatWire
import PhotosUI
import SwiftUI
import UIKit
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync

/// The conversation screen's shell (unified chat spec §6.3): `ChatUI`'s feed and composer over the hub's
/// `RelayChatClient`, with the phone's own parts around them — the title, the placeholder while no feed is here, the
/// line over the feed (an approval's answer, a send a relaunch gave back, a file that did not attach, a turn waiting
/// for a slot), the attachment picker, the artifact and sources sheets, and the alert routing.
struct ChatConversationView: View {
    static let newChatLine = "It answers with your Slack, mail, Jira, meetings and memory."
    static let newChatTitle = "New chat"
    static let waitingForSlot = "Waiting for a free slot"
    static let photoName = "Photo.jpg"
    static let removeFileLabel = "Remove file"
    /// One style value: a fresh one per render would invalidate the whole feed each time.
    private static let style: any ChatUIStyle = PhoneChatStyle()

    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    let center: ChatsCenter
    let shot: ChatsShot?
    private let route: ChatRoute
    @State private var conversation: ChatConversationModel
    @State private var composer: ChatComposerModel
    @State private var artifact: ChatArtifactContent?
    @State private var sources: [ChatSource]?
    @State private var attachNotice: String?
    @State private var attaching = false
    @State private var camera = false
    @State private var library = false
    @State private var files = false
    @State private var photos: [PhotosPickerItem] = []

    init(route: ChatRoute, center: ChatsCenter, shot: ChatsShot? = nil) {
        self.route = route
        self.center = center
        self.shot = shot
        let (conversation, composer) = center.conversation(route)
        _conversation = State(initialValue: conversation)
        _composer = State(initialValue: composer)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            screen(inputs: ChatsGateInputs.current(env, shot: shot, snapshot: center.snapshot, now: context.date))
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $artifact) { artifact in
            NavigationStack {
                ScrollView {
                    ArtifactViewer(artifact: artifact, openURL: { openURL($0) }, copy: { UIPasteboard.general.string = $0 })
                        .padding(Spacing.large)
                        .environment(\.chatUIStyle, Self.style)
                        .environment(\.chatHostText, .phone(hubName))
                }
                .navigationTitle(artifact.title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: Binding(get: { sources != nil }, set: { if !$0 { sources = nil } })) {
            ChatSourcesList(sources: sources ?? []) { openURL($0) }
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
                if let data { attach(data: data, fileName: Self.photoName) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $library, selection: $photos, maxSelectionCount: 4, matching: .images)
        .onChange(of: photos) { _, items in loadPhotos(items) }
        .fileImporter(isPresented: $files, allowedContentTypes: ChatAttachmentMenu.fileTypes, allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .onChange(of: composer.draft) { keepDraft() }
        .onChange(of: composer.quotes) { keepDraft() }
        .onChange(of: alertScreen) { old, new in
            if let old { env.navigation.screenDisappeared(old) }
            if let new { env.navigation.screenAppeared(new) }
        }
        .onAppear { if let alertScreen { env.navigation.screenAppeared(alertScreen) } }
        .onDisappear { if let alertScreen { env.navigation.screenDisappeared(alertScreen) } }
    }

    private var title: String {
        if let title = conversation.feed?.conversation.title, !title.isEmpty { return title }
        guard let id = conversation.conversationID else { return Self.newChatTitle }
        return center.snapshot.list?.conversations.first { $0.id == id }?.title ?? ""
    }

    /// The tower's name for the artifact sheet's lines (the screen reads it from its gate inputs).
    private var hubName: String { (shot?.heartbeat ?? env.workbenchReplica.snapshot.heartbeat)?.macName ?? "" }

    /// The alert routing's screen: a saved conversation on the hub on screen.
    private var alertScreen: AlertDestination? {
        guard let id = conversation.conversationID, let hubID = env.activeHubID else { return nil }
        return .chat(hubID: hubID, conversationID: id)
    }

    @ViewBuilder
    private func screen(inputs: ChatsGateInputs) -> some View {
        let gate = ChatsGateModel(inputs)
        let hold = center.hold(conversation.conversationID, composerSending: composer.isSending, host: inputs.host)
        ChatUI.ChatConversationView(
            conversation: conversation, composer: composer, partActions: partActions(inputs), onAttach: { attaching = true },
            composerAccessory: pills, focusMessageID: route.messageID
        )
        .environment(\.chatUIStyle, Self.style)
        .environment(\.chatHostText, .phone(inputs.heartbeat?.macName ?? ""))
        .overlay(alignment: .center) {
            if conversation.messages.isEmpty { placeholder(inputs.host, online: gate.online) }
        }
        .toolbar {
            if let chip = ChatNavChip(mac: inputs.mac, relayUnreachable: inputs.relayUnreachable) {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: Spacing.small) {
                        Circle().fill(chip.tone.color).frame(width: PhoneMetrics.macDot, height: PhoneMetrics.macDot)
                        Text(chip.word).font(TypeScale.pill).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Spacing.regular)
                    .padding(.vertical, Spacing.small)
                    .background(Fill.rest, in: Capsule())
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .onChange(of: hold, initial: true) { composer.hold = hold }
        .onChange(of: hasFiles, initial: true) { composer.hasShellAttachments = hasFiles }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let line = topLine {
                Text(line)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Spacing.large)
                    .padding(.vertical, Spacing.small)
                    .background(PhoneSurface.page)
                    .accessibilityIdentifier("chat.phoneLine")
            }
        }
        .onChange(of: gate, initial: true) { center.setGate(gate, host: inputs.host) }
    }

    /// The phone's line over the feed, newest concern first.
    private var topLine: String? {
        if let attachNotice { return attachNotice }
        if let id = conversation.conversationID ?? (route.isNew ? 0 : nil), let notice = center.drafts.draft(id).notice { return notice }
        if conversation.feed?.conversation.lease?.waitingSlot == true { return Self.waitingForSlot }
        return nil
    }

    @ViewBuilder
    private func placeholder(_ host: TowerHost, online: Bool) -> some View {
        Group {
            if conversation.conversationID == nil {
                VStack(spacing: Spacing.regular) {
                    Text(ChatText.newChatTitle(host)).font(TypeScale.screenTitle)
                    Text(Self.newChatLine).font(TypeScale.meta).foregroundStyle(.secondary)
                }
            } else if let id = conversation.conversationID, conversation.feed == nil {
                if online, center.client.unanswered.contains(id) {
                    // Mockup 2g: no feed within the patience.
                    VStack(spacing: Spacing.regular) {
                        Text(ChatText.noAnswer(host)).font(TypeScale.meta).foregroundStyle(.secondary)
                        Button(ChatsGateModel.retry) { center.client.retryFeed(id) }
                            .buttonStyle(SecondaryActionStyle())
                            .frame(maxWidth: PhoneMetrics.gateButton)
                    }
                } else {
                    Text(online ? ChatText.opening(host) : ChatText.neverLoaded(host))
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.large)
    }

    /// Files wait in the draft: a saved chat may send them with no text.
    private var hasFiles: Bool { !center.drafts.draft(conversation.conversationID ?? 0).attachments.isEmpty }

    /// The files waiting to go with the next send (mockup 2b's pills): their upload state, Retry on a refused one.
    private var pills: AnyView? {
        let key = conversation.conversationID ?? 0
        let files = center.drafts.draft(key).attachments
        guard !files.isEmpty else { return nil }
        return AnyView(ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.small) {
                ForEach(files) { file in
                    HStack(spacing: Spacing.small) {
                        Image(systemName: file.isImage ? "photo" : "doc")
                        Text(file.name).lineLimit(1)
                        switch file.state {
                        case .uploading: ProgressView().controlSize(.mini)
                        case .failed: Button(ChatsGateModel.retry) { center.retryAttachment(file.id, conversation: key) }
                        case .ready, .uploaded: EmptyView()
                        }
                        Button { center.removeAttachment(file.id, conversation: key) } label: { Image(systemName: "xmark") }
                            .disabled(file.state == .uploading)
                            .accessibilityLabel(Self.removeFileLabel)
                    }
                    .font(TypeScale.pill)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.regular)
                    .padding(.vertical, Spacing.small)
                    .background(Fill.card, in: Capsule())
                }
            }
        })
    }

    private func partActions(_ inputs: ChatsGateInputs) -> ChatPartActions {
        let client = center.client
        let permissions = inputs.grant?.permissionsAllowed ?? false
        let host = inputs.host
        return ChatPartActions(
            openURL: { openURL($0) },
            copy: { UIPasteboard.general.string = $0 },
            openArtifact: { artifact = $0 },
            openSources: { sources = $0 },
            approvals: approvals(client: client, permissions: permissions, host: host)
        )
    }

    /// The approval card's services on the phone (ask #1411): the hub's `chat_action_answer` and the card's state line
    /// only — no editing (the relay answer has no patch), no Approve all, Dismiss or Retry.
    private func approvals(client: RelayChatClient, permissions: Bool, host: TowerHost) -> ChatApprovalServices {
        let conversation = conversation
        return ChatApprovalServices(
            decide: { action, answer in
                switch answer {
                case .approve(nil): Task { await client.decide(action, .approve, permissions: permissions) }
                case .reject: Task { await client.decide(action, .reject, permissions: permissions) }
                // The relay answer carries no patch: an edited approve is never sent as a plain one.
                case .approve(_?): break
                }
            },
            state: { action in client.approvalCard(action, permissions: permissions, host: host).state },
            sessionHoldsCall: { ConnectorCallProposal.sessionHolds($0, runningTurnID: conversation.runningTurnID) }
        )
    }

    private func keepDraft() {
        center.keepDraft(conversation.conversationID ?? 0, text: composer.draft, quotes: composer.quotes)
    }

    // MARK: - Files

    /// Prepares and stages a picked file into the draft: it uploads with the next send (`chat_attachment` first).
    private func attach(data: Data, fileName: String) {
        attachNotice = center.attach(data: data, fileName: fileName, conversation: conversation.conversationID ?? 0)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photos = []
        Task {
            for (index, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                attach(data: data, fileName: "Photo \(index + 1).\(ext)")
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                attachNotice = ChatSendCoordinator.couldNotSend
                continue
            }
            attach(data: data, fileName: url.lastPathComponent)
        }
    }
}

/// An answer's sources, grouped as on the Mac (`ChatSourceGrouping`); a source with a link opens it.
struct ChatSourcesList: View {
    static let title = "Sources"

    let sources: [ChatSource]
    let open: (URL) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(ChatSourceGrouping.groups(sources)) { group in
                    Section(group.name) {
                        ForEach(Array(group.sources.enumerated()), id: \.offset) { _, source in
                            row(source)
                        }
                    }
                }
            }
            .navigationTitle(Self.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func row(_ source: ChatSource) -> some View {
        let label = VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(ChatSourceGrouping.displayTitle(source)).font(TypeScale.rowTitle).lineLimit(2)
            if let snippet = source.snippet, !snippet.isEmpty {
                Text(snippet).font(TypeScale.meta).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        if let url = SourceLinkResolver.url(for: source, jiraSiteURL: nil) {
            Button { open(url) } label: { label }.buttonStyle(.plain)
        } else {
            label
        }
    }
}

/// The nav-bar chip while the hub does not answer (mockup 2e): "asleep" or "offline", in the Mac status chip's tone.
struct ChatNavChip: Equatable {
    static let asleep = "asleep"
    static let offline = "offline"

    let word: String
    let tone: PhoneTone

    /// Nil while the hub answers.
    init?(mac: MacReachability, relayUnreachable: Bool) {
        switch mac {
        case .online:
            guard relayUnreachable else { return nil }
            (word, tone) = (Self.offline, .secondary)
        case .asleep:
            (word, tone) = (Self.asleep, .gray)
        case .offline:
            (word, tone) = (Self.offline, .secondary)
        }
    }
}
