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

    /// The alert routing's screen: a saved conversation on the hub on screen.
    private var alertScreen: AlertDestination? {
        guard let id = conversation.conversationID, let hubID = env.activeHubID else { return nil }
        return .chat(hubID: hubID, conversationID: id)
    }

    @ViewBuilder
    private func screen(inputs: ChatsGateInputs) -> some View {
        let gate = ChatsGateModel(inputs)
        ChatUI.ChatConversationView(conversation: conversation, composer: composer, partActions: partActions(inputs)) {
            attaching = true
        }
        .environment(\.chatUIStyle, Self.style)
        .overlay(alignment: .center) {
            if conversation.messages.isEmpty { placeholder(inputs.host, online: gate.online) }
        }
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
        .onChange(of: gate, initial: true) { center.setGate(gate) }
    }

    /// The phone's line over the feed, newest concern first.
    private var topLine: String? {
        if let notice = center.client.approvalNotice { return notice }
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
            } else if conversation.feed == nil {
                Text(online ? ChatText.opening(host) : ChatText.neverLoaded(host))
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.large)
        .allowsHitTesting(false)
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
            decide: { payload, decision in
                Task { await client.decide(payload, decision, permissions: permissions, host: host) }
            }
        )
    }

    private func keepDraft() {
        center.keepDraft(conversation.conversationID ?? 0, text: composer.draft, quotes: composer.quotes)
    }

    // MARK: - Files

    /// Prepares a picked file (HEIC to JPEG, an image over the limit downsized, the shared limits) and stages it;
    /// the composer uploads it (`chat_attachment`), creating the chat first when it is new.
    private func attach(data: Data, fileName: String) {
        switch ChatAttachmentPrep.prepare(data: data, fileName: fileName) {
        case let .failure(rejection):
            attachNotice = rejection.message
        case let .success(prepared):
            do {
                let staged = try ChatAttachmentPrep.stage(prepared, in: center.staging)
                attachNotice = nil
                let upload = ChatSealedUpload(uploadID: staged.id, name: staged.name, mime: staged.mime, size: staged.size, file: staged.file)
                Task { await composer.attach(.sealedUpload(upload)) }
            } catch {
                attachNotice = ChatSendCoordinator.couldNotSend
            }
        }
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
