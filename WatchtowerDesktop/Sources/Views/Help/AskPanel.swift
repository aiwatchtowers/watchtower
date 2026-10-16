import AppKit
import SwiftUI
import WatchtowerCore

/// Puts the ⌘/ "Ask Watchtower" panel over the main window's root content —
/// above every destination, the Workbench tab included.
struct AskPanelHost: ViewModifier {
    @Bindable var appState: AppState

    func body(content: Content) -> some View {
        content
            .overlay {
                if appState.isAskPanelShown {
                    AskPanel(appState: appState, center: appState.askCenter) { appState.isAskPanelShown = false }
                }
            }
    }
}

/// "Ask Watchtower" (spec 2026-10-16, approved mockup ask #238): a centred
/// card over a dimmed backdrop. Typing lists **Ask** (↩ asks), matching
/// **Guide** sections (open in the browser) and **Go to** screens (open the
/// screen, also ⌘↩). Asking swaps the list for a short help chat with no
/// tools; **Open in AI Chat** re-asks the first question there. Closing ends
/// the conversation (its engine is released, nothing is stored) and hands
/// the keyboard back to whatever had it.
struct AskPanel: View {
    let appState: AppState
    @Bindable var center: AskCenter
    let onClose: () -> Void

    private enum Entry: Identifiable {
        case ask(String)
        case guide(GuideSection)
        case screen(HelpScreen)

        var id: String {
            switch self {
            case .ask: "ask"
            case let .guide(section): "guide-\(section.id)"
            case let .screen(screen): "screen-\(screen.rawValue)"
            }
        }
    }

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var engine: EmbeddedChatEngine?
    @State private var asking = false
    @State private var previousResponder = PreviousFirstResponder()
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            card
                .padding(.top, 90)
                .padding(.horizontal, 16)
        }
        .onAppear {
            previousResponder.capture()
            center.startConversation()
        }
        .onDisappear {
            // Every way out (Esc, a screen link, the flag reset elsewhere)
            // ends the conversation.
            if let engine { appState.embeddedChatCenter.release(engine.spec.key) }
        }
        .task {
            await center.loadIfNeeded()
            await center.loadModels()
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let engine {
                conversation(engine)
            } else {
                results
            }
        }
        .frame(maxWidth: 640)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .task { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: engine == nil ? "magnifyingglass" : "questionmark.bubble")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if engine == nil {
                TextField("Ask Watchtower or search the guide", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .accessibilityLabel("Ask Watchtower")
                    .onChange(of: query) { _, _ in selectedIndex = 0 }
            } else {
                Text("Ask Watchtower").font(.title3)
                Spacer(minLength: 8)
                Button("Open in AI Chat", action: openInAIChat)
                    .buttonStyle(.borderless)
                    .disabled(appState.chatViewModel == nil)
            }
            Text("on \(appState.selectedDestination.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .lineLimit(1)
        }
        .padding(12)
    }

    // MARK: - Typing: Ask, Guide, Go to

    private var results: some View {
        let matches = center.matches(for: query, screens: appState.visibleHelpScreens)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = (trimmed.isEmpty ? [] : [Entry.ask(trimmed)])
            + matches.guide.map(Entry.guide) + matches.screens.map(Entry.screen)
        let selectedID = entries.indices.contains(selectedIndex) ? entries[selectedIndex].id : nil
        return VStack(alignment: .leading, spacing: 0) {
            if let error = center.indexError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if entries.isEmpty {
                            Text(trimmed.isEmpty ? "Type a question, or the name of a screen." : "No matches.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if case .guide = entry, index == firstIndex(of: .guide, in: entries) { sectionHeader("Guide") }
                            if case .screen = entry, index == firstIndex(of: .screen, in: entries) { sectionHeader("Go to") }
                            entryRow(entry, index: index, isSelected: entry.id == selectedID).id(entry.id)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Divider()
            Text("↑↓ choose  ↩ ask  esc close")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .background { keys(entries) }
    }

    private enum Kind { case guide, screen }

    private func firstIndex(of kind: Kind, in entries: [Entry]) -> Int? {
        entries.firstIndex {
            switch ($0, kind) {
            case (.guide, .guide), (.screen, .screen): true
            default: false
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func entryRow(_ entry: Entry, index: Int, isSelected: Bool) -> some View {
        Button { perform(entry) } label: {
            HStack(spacing: 10) {
                entryLabel(entry)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selectedIndex = index } }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func entryLabel(_ entry: Entry) -> some View {
        switch entry {
        case let .ask(text):
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text("Ask Watchtower: \"\(text)\"")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        case let .guide(section):
            Image(systemName: "book").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.heading).font(.callout).lineLimit(1)
                Text(section.pageTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        case let .screen(screen):
            Image(systemName: "arrow.right.square").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(screen.title).font(.callout)
        }
    }

    /// Hidden buttons: the field keeps the focus while ↑↓↩⌘↩esc reach
    /// these (key equivalents run before the field editor sees the key).
    private func keys(_ entries: [Entry]) -> some View {
        Group {
            Button("") { move(-1, count: entries.count) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { move(1, count: entries.count) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") {
                if entries.indices.contains(selectedIndex) { perform(entries[selectedIndex]) }
            }
            .keyboardShortcut(.return, modifiers: [])
            Button("") { openScreen(in: entries) }.keyboardShortcut(.return, modifiers: .command)
            Button("", action: close).keyboardShortcut(.escape, modifiers: [])
        }
        .hidden()
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    /// ⌘↩: the selected screen row, else the first one listed.
    private func openScreen(in entries: [Entry]) {
        let screens = entries.compactMap { entry -> HelpScreen? in
            if case let .screen(screen) = entry { return screen }
            return nil
        }
        if entries.indices.contains(selectedIndex), case let .screen(screen) = entries[selectedIndex] {
            perform(.screen(screen))
        } else if let first = screens.first {
            perform(.screen(first))
        }
    }

    private func perform(_ entry: Entry) {
        switch entry {
        case let .ask(text):
            ask(text)
        case let .guide(section):
            if let index = center.index, let url = section.url(in: index) { NSWorkspace.shared.open(url) }
        case let .screen(screen):
            appState.openNavLink(NavLink.url(screen.rawValue))
        }
    }

    // MARK: - The conversation

    /// Waits for the guide index and the model catalog first (a cold first
    /// ⌘/ may still be loading them — without the catalog the first answer
    /// would run on the strong tier); a failed load asks anyway, with no
    /// sections or the CLI's default model. A panel closed (or reopened on a
    /// new conversation) meanwhile sends nothing: no engine, no paid call.
    private func ask(_ text: String) {
        guard !asking else { return }
        asking = true
        Task {
            guard await center.prepareToAsk(isShown: { [appState] in appState.isAskPanelShown }) else { return }
            let spec = HelpChatSurface.spec(
                center: center,
                currentPage: { [appState] in appState.selectedDestination.title },
                screens: { [appState] in appState.visibleHelpScreens }
            )
            let engine = appState.embeddedChatCenter.engine(for: spec)
            center.history = { [weak engine] in engine?.messages.map(\.message) ?? [] }
            self.engine = engine
            engine.send(text)
        }
    }

    private func conversation(_ engine: EmbeddedChatEngine) -> some View {
        // Esc closes through the hidden button below (a key equivalent runs
        // before the composer sees the key), so the composer gets no onEscape.
        EmbeddedChatView(engine: engine, density: .compact, placeholder: "Ask a follow-up…",
                         accessory: { item in source(for: item) }, footer: { EmptyView() })
            .embeddedChatVisibility(engine.spec.key, in: appState.embeddedChatCenter)
            .frame(height: 420)
            .background {
                Button("", action: close).keyboardShortcut(.escape, modifiers: []).hidden()
            }
    }

    /// "From the guide: <page> › <heading>" under the answer it was built from.
    @ViewBuilder
    private func source(for item: ChatThreadItem) -> some View {
        if let section = center.sources[item.id], let index = center.index, let url = section.url(in: index) {
            Link("From the guide: \(section.pageTitle) › \(section.heading)", destination: url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// A new AI Chat conversation asking the panel's first question, with
    /// the full chat's tools and history.
    private func openInAIChat() {
        guard let chat = appState.chatViewModel,
              let question = engine?.messages.first(where: { $0.message.isUser })?.message.text else { return }
        chat.newConversation()
        chat.send(text: question)
        appState.selectedDestination = .chat
        onClose()
    }

    private func close() {
        onClose()
        previousResponder.restore()
    }
}
