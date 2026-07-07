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
/// Send routing (Plan 5 Decision 7): every send goes through ONE of two
/// `MobileAgentBackend`s — the relay (the Mac answers) by default, the
/// on-device direct agent when THIS session's `direct_mode` flag is set. The
/// flag flips only on an explicit user choice via the confirm dialog /
/// toolbar toggle — never a silent switch.
///
/// Writer discipline: turns are written by the backends (both end in
/// `assembler.send` — the assembler owns the chat tables); the VM's only
/// direct store write is the `direct_mode` routing flag, a local UI
/// preference column no pipeline reads.
@MainActor
@Observable
final class ChatThreadViewModel {
    /// nil until the first send of a NEW chat mints the session.
    private(set) var sessionID: String?
    private(set) var messages: [ChatMessage] = []
    var draft = ""
    /// Set when the backend's send itself throws (transport failure, missing
    /// API key). The draft is NOT cleared on that path — send() persisted
    /// nothing, so the typed text must survive for a retry
    /// (ChatAssembler.send's contract, shared by both backends).
    private(set) var sendErrorMessage: String?
    /// This session's persisted opt-in (`chat_sessions.direct_mode`),
    /// mirrored locally: read once at `start`, written through
    /// `setDirectMode`. This VM is the flag's only writer, so a live
    /// observation would be redundant.
    private(set) var directMode = false
    /// Non-nil presents the opt-in confirmation dialog. The two contexts
    /// differ on confirm/decline behavior — see `confirmDirectOffer`.
    private(set) var directOfferContext: DirectOfferContext?

    /// Which affordance asked for the opt-in dialog.
    enum DirectOfferContext: Equatable {
        /// The unreachable banner's "Answer directly" on an existing thread.
        case banner
        /// The held-back FIRST send of a new chat (key present + Mac
        /// unreachable): the dialog decides which backend that send uses.
        case firstSend
    }

    private var cancellable: AnyDatabaseCancellable?
    private var store: ReplicaStore?
    private var directBackend: (any MobileAgentBackend)?
    private var relayBackend: (any MobileAgentBackend)?
    private var hasKey: (() -> Bool)?
    private var isReachable: ((Date) -> Bool)?
    /// Set when the new-chat offer was explicitly declined, so retries after
    /// a failed relay send don't nag — "ask once BEFORE the first send".
    private var firstSendOfferDeclined = false
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
        direct: any MobileAgentBackend,
        relay: any MobileAgentBackend,
        hasKey: @escaping () -> Bool,
        isReachable: @escaping (Date) -> Bool,
        sessionID: String?
    ) {
        guard self.store == nil else { return }
        self.store = store
        directBackend = direct
        relayBackend = relay
        self.hasKey = hasKey
        self.isReachable = isReachable
        self.sessionID = sessionID
        if let sessionID {
            // Restore the persisted opt-in; a failed read falls back to the
            // relay route — the safe default (never a silent switch TO direct).
            do {
                directMode = try store.chatSessions()
                    .first { $0.id == sessionID }?.directMode ?? false
            } catch {
                Self.logger.error("direct_mode restore failed, defaulting to relay: \(error.localizedDescription, privacy: .public)")
                directMode = false
            }
            observe()
        }
    }

    /// The composer's send tap. `now` is injectable so the offer-precondition
    /// tests run on frozen clocks (project near-midnight discipline).
    func send(now: Date = Date()) async {
        guard canSend else { return }
        // A NEW chat while a key exists and the Mac is unreachable asks ONCE
        // before the first send (Decision 7): the dialog decides which
        // backend that send uses. Declining routes the relay, as today.
        if sessionID == nil, !directMode, !firstSendOfferDeclined,
           hasKey?() == true, isDesktopUnreachable(now: now) {
            directOfferContext = .firstSend
            return
        }
        await performSend(direct: directMode)
    }

    /// The banner's "Answer directly" tap — presents the confirm dialog.
    func offerDirect(_ context: DirectOfferContext) {
        directOfferContext = context
    }

    /// Dialog confirm. Context is a PARAMETER captured by the dialog button
    /// at render time, not re-read from state: the dialog's dismissal handler
    /// nils `directOfferContext` in a race with the button's async action.
    ///
    /// `.banner`: flips the flag only — NO automatic re-send. The typed text
    /// is still in the compose field (the send-throw contract keeps it
    /// there), and the user re-taps send themselves; auto-resending would
    /// ship text they never re-confirmed against the new backend.
    /// `.firstSend`: performs the held-back first send through the direct
    /// backend; the session it mints is flagged inside `performSend`.
    func confirmDirectOffer(_ context: DirectOfferContext) async {
        directOfferContext = nil
        setDirectMode(true)
        if context == .firstSend {
            await performSend(direct: true)
        }
    }

    /// Dialog decline. `.firstSend` sends via the relay as today (and stops
    /// re-asking for this chat); `.banner` changes nothing.
    func declineDirectOffer(_ context: DirectOfferContext) async {
        directOfferContext = nil
        guard context == .firstSend else { return }
        firstSendOfferDeclined = true
        await performSend(direct: false)
    }

    /// Plain dialog dismissal (swipe / Cancel): no choice made — nothing
    /// sends, the draft stays, and the next send tap may ask again.
    func dismissDirectOffer() {
        directOfferContext = nil
    }

    /// The user's explicit route switch (confirm dialog / the toolbar chip's
    /// "Back to Mac relay"). Local mirror first — routing must flip
    /// immediately — then the persisted flag, so re-entering the thread
    /// restores the choice.
    func setDirectMode(_ enabled: Bool) {
        directMode = enabled
        persistDirectMode(enabled)
    }

    /// Banner affordance for this thread — see `DirectOptInState`.
    var optInState: DirectOptInState {
        DirectOptInState(hasKey: hasKey?() ?? false, directMode: directMode)
    }

    private func performSend(direct: Bool) async {
        let text = trimmedDraft
        guard !text.isEmpty, let backend = direct ? directBackend : relayBackend else { return }
        do {
            let ids = try await backend.sendTurn(text: text, sessionID: sessionID)
            // Clear ONLY on success — a throw above persisted nothing and the
            // draft must keep the typed text (see `sendErrorMessage`).
            draft = ""
            sendErrorMessage = nil
            if sessionID == nil {
                sessionID = ids.sessionID
                // A direct-confirmed first send flags the session the moment
                // its id exists (Decision 7).
                if directMode { persistDirectMode(true) }
                observe()
            }
        } catch {
            Self.logger.error("chat send failed: \(error.localizedDescription, privacy: .public)")
            sendErrorMessage = "Send failed: \(error.localizedDescription)"
        }
    }

    private func persistDirectMode(_ enabled: Bool) {
        guard let store, let sessionID else { return }
        do {
            try store.setDirectMode(sessionID: sessionID, enabled: enabled)
        } catch {
            Self.logger.error("direct-mode flag write failed: \(error.localizedDescription, privacy: .public)")
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

    /// What renders under a reply still waiting for its first chunk past
    /// `unreachableAfter` (the `showsWaitingBanner` timing above), split by
    /// route (Plan 6 Task 6): the relay warns the Mac is unreachable as
    /// before; a direct-mode thread gets the neutral "Still thinking…" hint
    /// instead — the phone answers itself, so Mac framing would mislead.
    enum WaitingHint: Equatable {
        case none
        case macUnreachable
        case stillThinking
    }

    func waitingHint(for message: ChatMessage, now: Date) -> WaitingHint {
        guard showsWaitingBanner(for: message, now: now) else { return .none }
        return directMode ? .stillThinking : .macUnreachable
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

// MARK: - Direct opt-in state

/// The unreachable banner's opt-in affordance, keyed off (hasKey,
/// directMode). A pure state function so the matrix is unit-tested without
/// views (the TimelineView only decides WHEN the banner shows; this decides
/// WHAT it offers).
enum DirectOptInState: Equatable {
    /// No stored API key: the button routes to Settings ("Set up offline
    /// agent…").
    case needsKey
    /// Key present, session on the relay: the button offers the confirm
    /// dialog ("Answer directly").
    case offerDirect
    /// Session opted in: the banner is suppressed — "answers need your
    /// desktop online" would be a lie while the phone answers itself — and
    /// the toolbar chip carries the state. A key removed AFTER opt-in still
    /// reads directActive: the chip's "Back to Mac relay" must stay
    /// reachable, and a direct send without a key fails into the send-error
    /// banner (missingKey) with the draft kept.
    case directActive

    init(hasKey: Bool, directMode: Bool) {
        if directMode {
            self = .directActive
        } else {
            self = hasKey ? .offerDirect : .needsKey
        }
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
    @Environment(\.openSettingsTab) private var openSettingsTab
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
                            // No session context here, so no "Answer
                            // directly": the per-conversation opt-in lives in
                            // each thread. Keyless phones get the Settings
                            // shortcut.
                            MacUnreachableBanner(
                                affordance: env.hasAPIKey ? .informational : .setupKey(openSettingsTab)
                            )
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
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Text(session.updatedAt, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    // Direct-flagged sessions wear the same
                                    // bolt as the thread's toolbar chip
                                    // (Plan 6 Task 6).
                                    if session.directMode {
                                        Spacer(minLength: 8)
                                        Image(systemName: "bolt.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel("Direct API")
                                    }
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
    @Environment(\.openSettingsTab) private var openSettingsTab
    @State private var model = ChatThreadViewModel()
    /// nil = new chat; the VM adopts the minted session on the first send.
    let sessionID: String?

    var body: some View {
        VStack(spacing: 0) {
            // 5 s cadence: the 45 s inline-banner threshold and the heartbeat
            // banner both cross over WITHOUT a db write (see ChatView).
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(spacing: 0) {
                    // Suppressed while direct mode is ON: the phone answers
                    // this thread itself, so "answers need your desktop
                    // online" would mislead — the toolbar chip carries the
                    // state instead.
                    if model.isDesktopUnreachable(now: context.date), model.optInState != .directActive {
                        MacUnreachableBanner(affordance: bannerAffordance)
                            .padding([.horizontal, .top], 12)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(model.messages) { message in
                                    ChatBubbleView(message: message)
                                        .id(message.id)
                                    // Route-split wait state: relay threads
                                    // warn about the Mac, direct threads get
                                    // the neutral hint (see `waitingHint`).
                                    switch model.waitingHint(for: message, now: context.date) {
                                    case .none:
                                        EmptyView()
                                    case .macUnreachable:
                                        MacUnreachableBanner(affordance: bannerAffordance)
                                    case .stillThinking:
                                        StillThinkingHint()
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
        .toolbar {
            // Direct mode is never ambient (Decision 7): while ON the thread
            // wears the chip in its bar, and the way back to the relay lives
            // in the same control.
            if model.directMode {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Back to Mac relay") { model.setDirectMode(false) }
                    } label: {
                        Label("Direct API", systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .confirmationDialog(
            "Answer directly from this phone?",
            isPresented: Binding(
                get: { model.directOfferContext != nil },
                set: { if !$0 { model.dismissDirectOffer() } }
            ),
            titleVisibility: .visible
        ) {
            // Context is captured HERE, at render time: the dismissal
            // binding nils it in a race with the buttons' async actions.
            if let context = model.directOfferContext {
                Button("Answer directly") {
                    Task { await model.confirmDirectOffer(context) }
                }
                if context == .firstSend {
                    Button("Send via Mac relay") {
                        Task { await model.declineDirectOffer(context) }
                    }
                }
                Button("Cancel", role: .cancel) { model.dismissDirectOffer() }
            }
        } message: {
            Text("Uses your Anthropic API key. The phone's copy has summaries only — no raw Slack messages.")
        }
        .onAppear {
            model.start(
                store: env.store,
                direct: env.directAgent,
                relay: env.relayBackend,
                hasKey: { env.hasAPIKey },
                isReachable: env.feed.isDesktopReachable,
                sessionID: sessionID
            )
        }
    }

    /// What the unreachable banner offers (never rendered in
    /// `.directActive` — the banner itself is suppressed then).
    private var bannerAffordance: MacUnreachableBanner.Affordance {
        switch model.optInState {
        case .needsKey: .setupKey(openSettingsTab)
        case .offerDirect: .answerDirectly { model.offerDirect(.banner) }
        case .directActive: .informational
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                // Honest placeholder: in direct mode the desktop is out of
                // the loop for this thread.
                model.directMode ? "Ask this phone…" : "Ask your desktop…",
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

// MARK: - Still-thinking hint

/// The direct-mode wait hint (Plan 6 Task 6): a direct-flagged thread whose
/// reply is still pending past `ChatAssembler.unreachableAfter` says the
/// phone is still working — neutral copy, deliberately NOTHING about the
/// Mac: the desktop is out of the loop for this thread, so the unreachable
/// framing would mislead.
private struct StillThinkingHint: View {
    var body: some View {
        Label("Still thinking…", systemImage: "ellipsis.bubble")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Unreachable banner

/// Liveness banner (spec §2): shown at tab level when the desktop heartbeat
/// is stale or was never seen, and inline under a reply that has waited past
/// `ChatAssembler.unreachableAfter`.
///
/// Plan 5 Task 7: the Plan-4 disabled "coming soon" stub became the live
/// opt-in entry — no key routes to Settings, a saved key offers the confirm
/// dialog. The sessions LIST shows the informational variant when a key
/// exists: the opt-in is per conversation, so the live button belongs to the
/// thread (and to the new-chat composer via the pre-first-send ask).
struct MacUnreachableBanner: View {
    enum Affordance {
        /// Label only — no button (sessions list with a key saved).
        case informational
        /// No key: "Set up offline agent…" jumps to the Settings tab.
        case setupKey(() -> Void)
        /// Key + relay session: "Answer directly" opens the confirm dialog.
        case answerDirectly(() -> Void)
    }

    var affordance: Affordance = .informational

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Mac unreachable — answers need your desktop online",
                systemImage: "desktopcomputer.trianglebadge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            switch affordance {
            case .informational:
                EmptyView()
            case .setupKey(let open):
                Button("Set up offline agent…", action: open)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            case .answerDirectly(let offer):
                Button("Answer directly", action: offer)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
