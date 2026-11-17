import AppKit
import ChatUI
import ChatWire
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The composer of every Mac surface, state by state (#1822 T13): rendered before and after the composer moved into
/// `ChatUI`, so the two renders can be compared name by name. Synthetic data only.
@MainActor
enum ComposerShotFixtures {
    private static var poolPaths: [String] = []
    private static var chats: [ChatViewModel] = []
    private static var held: [Any] = []
    private static var files: URL?

    static func cleanUp() {
        chats = []
        held = []
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
        if let files { try? FileManager.default.removeItem(at: files) }
        files = nil
    }

    static var shots: [DesignShot] {
        let wide = NSSize(width: 560, height: 0)
        return [
            DesignShot(name: "composer-main-empty", size: wide) { main { _ in } },
            DesignShot(name: "composer-main-typing", size: wide) { main { $0.composer.draft = typed } },
            DesignShot(name: "composer-main-streaming", size: wide) { main(running: true) { _ in } },
            DesignShot(name: "composer-main-narrow", size: NSSize(width: 340, height: 0)) {
                main { $0.composer.draft = typed }
            },
            DesignShot(name: "composer-main-attachments", size: wide) {
                main { vm in
                    vm.composer.draft = "What do these say?"
                    settle { for url in sampleFiles() { await vm.composer.attach(.path(url.path)) } }
                }
            },
            DesignShot(name: "composer-main-attachments-importing", size: wide) {
                main(client: ComposerShotClient(holdsAttach: true)) { vm in
                    vm.composer.draft = "Here are the notes"
                    let composer = vm.composer
                    held.append(Task { await composer.attach(.path("/tmp/acme/meeting-notes.md")) })
                    settle { composer.importing.isEmpty == false }
                    held.append(Task { await composer.send() })
                    settle { composer.isWaitingForAttachments }
                }
            },
            DesignShot(name: "composer-main-attachment-error", size: wide) {
                main { vm in
                    vm.composer.draft = "Summarise the pasted log"
                    vm.errorMessage = "Couldn't attach the pasted text: the disk is full"
                }
            },
            DesignShot(name: "composer-main-refused-kind", size: wide) {
                // The refused kind's notice is the field's own state after a drop or paste; the shot shows the field
                // of a provider that reads no images or PDFs (`ChatComposerFieldAttachmentTests` covers the notice).
                refusedKind()
            },
            DesignShot(name: "composer-main-long-paste", size: wide) {
                main(maxHeight: 160) { $0.composer.draft = longText }
            },
            DesignShot(name: "composer-main-quotes", size: wide) {
                main { vm in
                    vm.composer.addQuote("The rollout starts with the internal group next Tuesday.")
                    vm.composer.addQuote("The staging check was never run.")
                    vm.composer.quotes[0].comment = "Which group exactly?"
                }
            },
            DesignShot(name: "composer-main-mention-picker", size: wide) {
                main { vm in
                    vm.composer.draft = "Ask @an"
                    openPicker(vm, text: "Ask @an")
                }
            },
            DesignShot(name: "composer-main-skill-picker", size: wide) {
                main { vm in
                    vm.composer.draft = "/re"
                    openPicker(vm, text: "/re")
                }
            },
            DesignShot(name: "composer-main-chips", size: wide) {
                main { vm in
                    pick(vm, text: "/re", row: 0)
                    pick(vm, text: vm.composer.draft + "Ask @an", row: 0)
                    pick(vm, text: vm.composer.draft + "and @pa", row: 1)
                }
            },
            DesignShot(name: "composer-main-notice", size: wide) {
                main(client: ComposerShotClient(refusesTurns: true)) { vm in
                    vm.composer.draft = typed
                    let composer = vm.composer
                    settle { await composer.send() }
                }
            },
            DesignShot(name: "composer-main-editing", size: wide) { main { $0.beginEditingLast() } },
            DesignShot(name: "composer-main-dictation-active", size: wide) { dictating() },
            DesignShot(name: "composer-embedded-queued", size: NSSize(width: 460, height: 0)) {
                embedded(status: .queued, text: "Draft a comment for the owner of the session store", busy: true)
            },
            DesignShot(name: "composer-embedded-finishing", size: NSSize(width: 460, height: 0)) {
                embedded(status: .finishing, text: "", busy: true)
            },
            DesignShot(name: "composer-embedded-error", size: NSSize(width: 460, height: 0)) {
                embedded(status: .error("Couldn't send: the conversation could not be saved"), text: "Try again", busy: false)
            },
            DesignShot(name: "composer-help-panel", size: NSSize(width: 420, height: 0)) { helpPanel() },
            DesignShot(name: "composer-target-brief", size: NSSize(width: 560, height: 0)) { targetBrief() },
            DesignShot(name: "composer-workchat-attachments", size: wide) { workchatAttachments() }
        ]
    }

    private static let typed = "Compare the Q3 roadmap with the Q2 plan and list what moved"
    private static let longText = Array(repeating: "The import job reads every row of the export, checks the schema and "
        + "writes the rows it accepts; a refused row is logged with its line number.", count: 8).joined(separator: "\n")

    // MARK: - The main chat

    /// The main chat's composer over a chat with one exchange; `prepare` sets the state the shot shows.
    private static func main(
        client: ComposerShotClient = ComposerShotClient(),
        running: Bool = false,
        maxHeight: CGFloat = 120,
        _ prepare: (ChatViewModel) -> Void
    ) -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            poolPaths.append(path)
            let vm = ChatViewModel(client: client, dbPool: pool)
            chats.append(vm)
            let feed = ChatFeed(
                conversation: ChatFeed.Conversation(
                    id: 7, title: "Q3 roadmap", lease: running ? ChatFeed.Lease(owner: "hub", turnID: "turn-1") : nil
                ),
                messages: [
                    ChatFeed.Message(id: 1, role: "user", text: "Summarise the Q3 roadmap threads",
                                     createdAt: Date(timeIntervalSince1970: 1_794_000_000)),
                    ChatFeed.Message(id: 2, role: "assistant", text: "The roadmap has three threads.",
                                     status: running ? "pending" : "complete",
                                     createdAt: Date(timeIntervalSince1970: 1_794_000_000))
                ]
            )
            vm.select(conversationID: 7)
            vm.conversation.stop()
            vm.conversation.store.apply(.snapshot(feed))
            vm.conversation.reachability = .connected
            prepare(vm)
            return AnyView(mainComposer(vm, maxHeight: maxHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.vertical, Spacing.medium)
                .macChatStyle(hooks: ChatMacArtifactHooks())
                .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    private static func mainComposer(_ vm: ChatViewModel, maxHeight: CGFloat) -> some View {
        MainChatComposer(chatVM: vm, modelSuggestions: [], maxHeight: maxHeight)
    }

    private static func picker(_ vm: ChatViewModel) -> ComposerPickerModel { vm.composer.picker }

    /// Opens the `@`/`/` picker on `text` (caret at the end) and waits for its rows.
    private static func openPicker(_ vm: ChatViewModel, text: String) {
        let picker = picker(vm)
        picker.update(text: text, cursor: text.utf16.count)
        settle { await picker.searchSettled() }
    }

    /// Picks row `row` of the picker opened on `text`: the chip it makes and the text it leaves.
    private static func pick(_ vm: ChatViewModel, text: String, row: Int) {
        openPicker(vm, text: text)
        if let edit = picker(vm).accept(index: row, text: text, cursor: text.utf16.count) {
            vm.composer.draft = edit.text
        }
    }

    /// The main composer while dictation writes into it: the field's highlight and the mic's recording state.
    private static func dictating() -> AnyView {
        do {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "ComposerShotFixtures-\(UUID().uuidString)"))
            defaults.set("small", forKey: DictationEngineChoice.defaultsKey)
            let center = DictationCenter(
                recorderFactory: { FakeMicRecorder() },
                engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: []), supportsLive: true) },
                runnerResolver: { nil },
                defaults: defaults,
                engineIdleTTL: .seconds(900)
            )
            held.append(center)
            center.start(targetID: "chat.workspace", mode: .chat, onLiveText: { _ in }, onResult: { _ in })
            return AnyView(main { $0.composer.draft = "Compare the Q3 roadmap" }
                .environment(\.dictationCenter, center))
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// A text file, an image and a PDF under a scratch folder, so each chip draws its own icon.
    private static func sampleFiles() -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("composer-shots-\(UUID().uuidString)")
        files = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 32))
        let pdf = Data("%PDF-1.4\n%acme\n".utf8)
        let samples: [(String, Data)] = [
            ("meeting-notes.md", Data("# Notes\n".utf8)),
            ("dashboard-screenshot-with-a-long-name.png", png),
            ("q3-roadmap.pdf", pdf)
        ]
        return samples.map { name, data in
            let url = dir.appendingPathComponent(name)
            try? data.write(to: url)
            return url
        }
    }

    // MARK: - The other surfaces

    /// An embedded chat's composer in one of its status states (`EmbeddedChatComposer`'s bar and field).
    private static func embedded(status: ChatComposerStatus, text: String, busy: Bool) -> AnyView {
        var stored = text
        return AnyView(ChatComposerBar(
            status: status,
            input: ChatComposerField(
                text: Binding(get: { stored }, set: { stored = $0 }),
                isStreaming: busy,
                config: ChatComposerFieldConfig(placeholder: "Ask about this task",
                                                maxHeight: ChatDensity.regular.composerMaxHeight,
                                                dictationTargetID: "chat.embedded.shot"),
                onSend: {},
                onStop: status == .finishing ? nil : {}
            )
        )
        .macComposerStyle()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, Spacing.medium)
        .macChatStyle(hooks: ChatMacArtifactHooks(), look: .embedded)
        .detailBackground())
    }

    /// The field of a provider that reads no images or PDFs (U1): the paperclip picks text files only.
    private static func refusedKind() -> AnyView {
        var stored = "Read the attached screenshot"
        return AnyView(ChatComposerBar(input: ChatComposerField(
            text: Binding(get: { stored }, set: { stored = $0 }),
            isStreaming: false,
            config: ChatComposerFieldConfig(placeholder: "Ask about your work…",
                                            attachUnavailableReason: ProviderCapabilities.none.attachUnavailableReason),
            onSend: {},
            onAttachFiles: { _ in }
        ))
        .macComposerStyle()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, Spacing.medium)
        .macChatStyle(hooks: ChatMacArtifactHooks())
        .detailBackground())
    }

    /// The ⌘/ panel's composer (`HelpChatPanel`).
    private static func helpPanel() -> AnyView {
        var stored = "How do I add a Jira account?"
        return AnyView(ChatComposerBar(input: ChatComposerField(
            text: Binding(get: { stored }, set: { stored = $0 }),
            isStreaming: false,
            config: ChatComposerFieldConfig(placeholder: "Ask how Watchtower works…", maxHeight: 120)
        ) {})
        .macComposerStyle()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, Spacing.medium)
        .macChatStyle(hooks: ChatMacArtifactHooks())
        .background(.regularMaterial))
    }

    /// The target page's assistant line (`TargetDetailView.assistantInlineInput`).
    private static func targetBrief() -> AnyView {
        var stored = ""
        return AnyView(HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.purple)
                .padding(.bottom, 14)
            ChatComposerBar(input: ChatComposerField(
                text: Binding(get: { stored }, set: { stored = $0 }),
                isStreaming: false,
                config: ChatComposerFieldConfig(placeholder: "Ask the assistant about this target…",
                                                dictationTargetID: "chat.target-assistant.1")
            ) {})
            .macComposerStyle()
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    /// The Workchat composer with two files attached and a line typed.
    private static func workchatAttachments() -> AnyView {
        let model = WorkchatModel(
            sessionID: 1, control: ShotWorkchatControl(), lineDelivery: SessionLineDelivery(terminalCenter: nil),
            kind: { .claude }, now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
        held.append(model)
        model.draft = "Look at these before the migration"
        model.attach(files: [URL(fileURLWithPath: "/tmp/acme/schema.sql"), URL(fileURLWithPath: "/tmp/acme/error.png")])
        return AnyView(WorkchatComposer(model: model, working: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.vertical, Spacing.medium)
            .detailBackground())
    }

    /// Runs `work` on the main actor and spins the run loop until it ends (at most 5 s).
    private static func settle(_ work: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in
            await work()
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// Spins the run loop until `condition` holds (at most 5 s).
    private static func settle(_ condition: @escaping @MainActor () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}

/// A Workchat control that reads nothing and sends nothing.
private final class ShotWorkchatControl: WorkchatControl {
    func lineCheck(_ sessionID: Int64) -> SessionControl.LineCheck { .hold(.agentBusy) }
    func workchatLineCheck(_ sessionID: Int64) -> SessionControl.LineCheck { .hold(.agentBusy) }
    func isWorking(_ sessionID: Int64) -> Bool { false }
    func interrupt(_ sessionID: Int64) async throws -> SessionControl.InterruptResult { .notWorking }
    func pendingPermission(_ sessionID: Int64) async throws -> SessionControl.PermissionPrompt? { nil }
    func answerPermission(requestID: Int64, sessionID: Int64, allow: Bool, decidedBy: String) async throws
        -> SessionControl.PermissionAnswer { .notFound }
}

/// The composer shots' engine: attaches files, answers the pickers, and holds or refuses what a shot asks.
private final class ComposerShotClient: ChatClient, @unchecked Sendable {
    private let holdsAttach: Bool
    private let refusesTurns: Bool
    private let lock = NSLock()
    private var nextID: Int64 = 100
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(holdsAttach: Bool = false, refusesTurns: Bool = false) {
        self.holdsAttach = holdsAttach
        self.refusesTurns = refusesTurns
    }

    func send(_ op: ChatOperation) async throws -> ChatEcho {
        switch op {
        case .attach:
            if holdsAttach {
                // The import never ends: the shot shows it running.
                await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } }
            }
            return .applied(.attachment(id: lock.withLock { nextID += 1; return nextID }))
        case .entitySearch:
            return .applied(.entities([
                ChatEntityHit(kind: "person", id: "1:U1", label: "Anna Lee", detail: "@anna"),
                ChatEntityHit(kind: "channel", id: "1:C1", label: "#announcements", detail: "Company news"),
                ChatEntityHit(kind: "jira", id: "PAY-12", label: "PAY-12", detail: "Refund flow")
            ]))
        case .skillsList:
            return .applied(.skills([
                ChatSkill(name: "release-notes", description: "Draft release notes from merged work"),
                ChatSkill(name: "review", description: "Review a pull request")
            ]))
        case .turn where refusesTurns:
            return .refused(code: "busy", message: "A reply from your phone is still running in this chat.")
        default:
            return .applied(.none)
        }
    }

    func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate> { AsyncStream { _ in } }
    func list() -> AsyncStream<ChatListUpdate> { AsyncStream { _ in } }
    var reachability: AsyncStream<ChatReachability> { AsyncStream { _ in } }
}
