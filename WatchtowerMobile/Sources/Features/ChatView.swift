import GRDB
import Observation
import os
import SwiftUI
import WatchtowerKit

// MARK: - Sessions view model

/// Sessions list state: a ValueObservation over `chat_sessions` (recent
/// first — `updated_at` is bumped by every turn AND every applied chunk) plus
/// the desktop-liveness read behind the "Mac unreachable" banner.
@MainActor
@Observable
final class ChatSessionsViewModel {
    private(set) var sessions: [ChatSession] = []
    private var cancellable: AnyDatabaseCancellable?
    // nonisolated: logged from the @Sendable observation onError closure.
    private nonisolated static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatSessionsViewModel")
    /// `RelayFeed.isDesktopReachable` in the app; injectable-clock closures
    /// in tests so the banner math is pinned against fixed instants.
    private var isReachable: ((Date) -> Bool)?

    func start(store: ReplicaStore, isReachable: @escaping (Date) -> Bool) {
        guard cancellable == nil else { return }
        self.isReachable = isReachable
        // From-db accessor on the closure's OWN db — a nested `writer.read`
        // traps on DatabasePool reentrancy (ReplicaObserver's rule).
        let observation = ValueObservation.tracking { db in
            try store.chatSessions(from: db)
        }
        cancellable = observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { Self.logger.error("chat sessions observation error: \($0.localizedDescription, privacy: .public)") },
            onChange: { [weak self] value in MainActor.assumeIsolated { self?.sessions = value } }
        )
    }

    /// Banner state: true when the last desktop heartbeat is stale (> 12 min)
    /// or was never seen. Before `start` wires the liveness read we cannot
    /// prove unreachability — no banner, rather than a first-frame flash.
    func isDesktopUnreachable(now: Date) -> Bool {
        guard let isReachable else { return false }
        return !isReachable(now)
    }
}

// MARK: - Thread view model

/// One thread's state: a ValueObservation over its `chat_messages` (assistant
/// text grows in place as chunks land), the composer draft + send path, and
/// the per-message waiting math behind the inline unreachable banner.
///
/// Writer discipline: the ONLY write path here is `assembler.send` — the
/// assembler owns the chat tables; this VM never touches them directly.
@MainActor
@Observable
final class ChatThreadViewModel {
    /// nil until the first send of a NEW chat mints the session.
    private(set) var sessionID: String?
    private(set) var messages: [ChatMessage] = []
    var draft = ""
    /// Set when `assembler.send` itself throws (transport failure). The
    /// draft is NOT cleared on that path — send() persisted nothing, so the
    /// typed text must survive for a retry (ChatAssembler.send's contract).
    private(set) var sendErrorMessage: String?

    private var cancellable: AnyDatabaseCancellable?
    private var store: ReplicaStore?
    private var assembler: ChatAssembler?
    private var isReachable: ((Date) -> Bool)?
    // nonisolated: logged from the @Sendable observation onError closure.
    private nonisolated static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatThreadViewModel")

    /// Send gate: whitespace-only drafts can never send — a blank send would
    /// mint a blank-titled session (Task 5 review note). Gates the button AND
    /// `send()` itself.
    var canSend: Bool { !trimmedDraft.isEmpty }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start(
        store: ReplicaStore,
        assembler: ChatAssembler,
        isReachable: @escaping (Date) -> Bool,
        sessionID: String?
    ) {
        guard self.store == nil else { return }
        self.store = store
        self.assembler = assembler
        self.isReachable = isReachable
        self.sessionID = sessionID
        if sessionID != nil { observe() }
    }

    func send() async {
        let text = trimmedDraft
        guard !text.isEmpty, let assembler else { return }
        do {
            let ids = try await assembler.send(text: text, sessionID: sessionID)
            // Clear ONLY on success — a throw above persisted nothing and the
            // draft must keep the typed text (see `sendErrorMessage`).
            draft = ""
            sendErrorMessage = nil
            if sessionID == nil {
                sessionID = ids.sessionID
                observe()
            }
        } catch {
            Self.logger.error("chat send failed: \(error.localizedDescription, privacy: .public)")
            sendErrorMessage = "Send failed: \(error.localizedDescription)"
        }
    }

    func clearSendError() {
        sendErrorMessage = nil
    }

    /// Scroll-follow trigger for the thread view: moves on every appended row
    /// AND whenever the LAST message's text grows in place (per applied
    /// chunk), so the view keeps following mid-stream output —
    /// `messages.count` alone misses in-place growth (Task 7 review Minor 3).
    struct ScrollKey: Equatable {
        let count: Int
        let lastTextLength: Int
    }

    var scrollKey: ScrollKey {
        ScrollKey(count: messages.count, lastTextLength: messages.last?.text.count ?? 0)
    }

    /// Same heartbeat-driven banner as the sessions list (see
    /// `ChatSessionsViewModel.isDesktopUnreachable`).
    func isDesktopUnreachable(now: Date) -> Bool {
        guard let isReachable else { return false }
        return !isReachable(now)
    }

    /// Inline unreachable banner at the message: the assistant reply row has
    /// waited past `ChatAssembler.unreachableAfter` (45 s) with NO chunk
    /// applied yet. Empty text is the first-chunk-pending signal (the store
    /// pairs both rows of a send at the same `createdAt`, and the desktop
    /// never streams an empty non-final chunk); once anything lands, the
    /// typing indicator carries the state instead.
    func showsWaitingBanner(for message: ChatMessage, now: Date) -> Bool {
        message.role == .assistant && !message.isComplete && message.text.isEmpty
            && Duration.seconds(now.timeIntervalSince(message.createdAt)) > ChatAssembler.unreachableAfter
    }

    private func observe() {
        guard cancellable == nil, let store, let sessionID else { return }
        // From-db accessor on the closure's own db (pool-reentrancy rule).
        let observation = ValueObservation.tracking { db in
            try store.chatMessages(inSession: sessionID, from: db)
        }
        cancellable = observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { Self.logger.error("chat messages observation error: \($0.localizedDescription, privacy: .public)") },
            onChange: { [weak self] value in MainActor.assumeIsolated { self?.messages = value } }
        )
    }
}

// MARK: - Bubble styling

/// Bubble styling decision, keyed EXCLUSIVELY off role + the `isError` flag.
/// NEVER off the text: legacy desktops prefix error text with "⚠️ ", and a
/// successful answer is free to start with the same glyph.
enum ChatBubbleStyle: Equatable {
    case user
    case assistant
    case error

    static func style(for message: ChatMessage) -> ChatBubbleStyle {
        if message.role == .user { return .user }
        return message.isError ? .error : .assistant
    }
}

// MARK: - Sessions list view

struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = ChatSessionsViewModel()
    @State private var showNewChat = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // TimelineView re-evaluates the banner as time passes — the
                // heartbeat goes stale WITHOUT a db write, so observation
                // alone would never re-fire it.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    List {
                        if model.isDesktopUnreachable(now: context.date) {
                            MacUnreachableBanner()
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                        // Deliberately NO animation on reorder: per-chunk
                        // updated_at bumps resort the list during streaming,
                        // and an animated jump per chunk would be jarring
                        // (Task 5 review note). Default List diffing swaps
                        // rows in place without movement animation.
                        ForEach(model.sessions) { session in
                            NavigationLink(value: session.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(session.updatedAt, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .overlay {
                        if model.sessions.isEmpty {
                            ContentUnavailableView(
                                "No chats yet",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("Ask your desktop agent anything.")
                            )
                        }
                    }
                }
                SyncStatusFooter()
            }
            .navigationTitle("Chat")
            .toolbar {
                Button {
                    showNewChat = true
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
            }
            .navigationDestination(for: String.self) { ChatThreadView(sessionID: $0) }
            .navigationDestination(isPresented: $showNewChat) { ChatThreadView(sessionID: nil) }
        }
        .onAppear { model.start(store: env.store, isReachable: env.feed.isDesktopReachable) }
    }
}

// MARK: - Thread view

struct ChatThreadView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = ChatThreadViewModel()
    /// nil = new chat; the VM adopts the minted session on the first send.
    let sessionID: String?

    var body: some View {
        VStack(spacing: 0) {
            // 5 s cadence: the 45 s inline-banner threshold and the heartbeat
            // banner both cross over WITHOUT a db write (see ChatView).
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(spacing: 0) {
                    if model.isDesktopUnreachable(now: context.date) {
                        MacUnreachableBanner()
                            .padding([.horizontal, .top], 12)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(model.messages) { message in
                                    ChatBubbleView(message: message)
                                        .id(message.id)
                                    if model.showsWaitingBanner(for: message, now: context.date) {
                                        MacUnreachableBanner()
                                    }
                                }
                            }
                            .padding(12)
                        }
                        // Keyed on `scrollKey`, not messages.count: the key
                        // also moves as chunks grow the last bubble in place,
                        // so the view follows mid-stream output. Unanimated
                        // on purpose — a spring per chunk would be jarring.
                        .onChange(of: model.scrollKey) {
                            if let last = model.messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            if let message = model.sendErrorMessage {
                ActionErrorRow(message: message) { model.clearSendError() }
                    .padding(.horizontal, 12)
            }
            composer
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.start(
                store: env.store,
                assembler: env.chat,
                isReachable: env.feed.isDesktopReachable,
                sessionID: sessionID
            )
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Ask your desktop…",
                text: Binding(get: { model.draft }, set: { model.draft = $0 }),
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            // Whitespace-only drafts can never send (Task 5 review note);
            // `send()` re-checks, so this is UI polish over a hard gate.
            .disabled(!model.canSend)
        }
        .padding(12)
    }
}

// MARK: - Bubble

private struct ChatBubbleView: View {
    let message: ChatMessage

    private var style: ChatBubbleStyle { ChatBubbleStyle.style(for: message) }

    var body: some View {
        HStack {
            if style == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                if style == .error {
                    Label("Desktop reported an error", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
                if message.text.isEmpty && !message.isComplete {
                    // Placeholder awaiting its first chunk.
                    TypingIndicator()
                } else {
                    Text(message.text)
                        .font(.subheadline)
                    if !message.isComplete {
                        // Mid-stream: the text above grows as chunks land.
                        TypingIndicator()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 14))
            if style != .user { Spacer(minLength: 48) }
        }
    }

    private var background: Color {
        switch style {
        case .user: .accentColor.opacity(0.18)
        case .assistant: Color(.secondarySystemBackground)
        case .error: .red.opacity(0.12)
        }
    }
}

/// Three pulsing dots — the "assistant is answering" state, shown while the
/// reply row is incomplete (`is_complete: 0`).
private struct TypingIndicator: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 6, height: 6)
                    .opacity(pulsing ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(index) * 0.15),
                        value: pulsing
                    )
            }
        }
        .foregroundStyle(.secondary)
        .onAppear { pulsing = true }
    }
}

// MARK: - Unreachable banner

/// Liveness banner (spec §2): shown at tab level when the desktop heartbeat
/// is stale or was never seen, and inline under a reply that has waited past
/// `ChatAssembler.unreachableAfter`. The "Answer directly" stub is Plan 5's
/// on-device fallback — visible but disabled so the affordance is
/// discoverable before it works.
struct MacUnreachableBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Mac unreachable — answers need your desktop online",
                systemImage: "desktopcomputer.trianglebadge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            Button("Answer directly (coming soon)") {}
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .disabled(true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
