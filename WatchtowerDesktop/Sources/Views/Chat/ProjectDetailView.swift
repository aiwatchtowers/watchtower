import AppKit
import GRDB
import SwiftUI
import WatchtowerCore

/// The project page shown in the chat detail area (spec 2026-10-26 §7):
/// the name, edited in place; the landing's composer bound to the project
/// (`ChatViewModel.openProject` sets `landingProjectID`, so its first
/// keystroke makes the chat there and its first turn leaves the page); the
/// project's chats; and, beside them or below under `HomeContent.twoColumnWidth`,
/// the Instructions and Knowledge cards. Navigation (open a chat, leave
/// after delete) goes through the callbacks: the split view owns the
/// history selection.
///
/// A project New Project… just made (`ChatViewModel.projectNameFocusRequest`,
/// set by `createProject`) opens with the name field focused.
struct ProjectDetailView: View {
    @State private var vm: ProjectDetailViewModel
    @Bindable var chatVM: ChatViewModel
    let dbPool: DatabasePool
    let modelSuggestions: [String]
    let maxComposerHeight: CGFloat
    let onOpenChat: (Int64) -> Void
    let onRenamed: () -> Void
    let onDeleted: (Int64) -> Void
    @State private var showSourcePicker = false
    @State private var confirmDelete = false
    @State private var dropTargeted = false
    @FocusState private var nameFocused: Bool

    init(
        projectID: Int64,
        chatVM: ChatViewModel,
        dbPool: DatabasePool,
        attachmentsRoot: URL?,
        modelSuggestions: [String],
        maxComposerHeight: CGFloat,
        onOpenChat: @escaping (Int64) -> Void,
        onRenamed: @escaping () -> Void,
        onDeleted: @escaping (Int64) -> Void,
        onPromptChanged: @escaping (Int64) -> Void
    ) {
        _vm = State(initialValue: ProjectDetailViewModel(
            projectID: projectID,
            dbPool: dbPool,
            attachmentsRoot: attachmentsRoot,
            importFile: ProjectDetailViewModel.storeImporter(dbPool: dbPool, rootDir: attachmentsRoot),
            onPromptChanged: onPromptChanged
        ))
        self.chatVM = chatVM
        self.dbPool = dbPool
        self.modelSuggestions = modelSuggestions
        self.maxComposerHeight = maxComposerHeight
        self.onOpenChat = onOpenChat
        self.onRenamed = onRenamed
        self.onDeleted = onDeleted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.page) {
                if let message = vm.errorMessage {
                    Text(message).font(.callout).foregroundStyle(Tone.error).textSelection(.enabled)
                }
                header
                HomeColumnsLayout(spacing: Spacing.wide) {
                    mainColumn
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        instructionsCard
                        knowledgeCard
                    }
                }
            }
            .padding(.horizontal, Spacing.hero)
            .padding(.top, Spacing.wide)
            .padding(.bottom, Spacing.hero)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            vm.load()
            if chatVM.projectNameFocusRequest == vm.projectID {
                chatVM.projectNameFocusRequest = nil
                // After the load enabled the field (a render later).
                Task { @MainActor in nameFocused = true }
            }
        }
        .onDisappear {
            commitName()
            Task {
                // An open editor's text is kept, like a name never submitted.
                if vm.instructionsEditor != nil { await vm.commitInstructionsEdit() }
                await vm.flush()
            }
        }
        .sheet(isPresented: $showSourcePicker) {
            ProjectSourcePickerSheet(dbPool: dbPool) { hit in Task { await vm.addSource(hit) } }
        }
        .confirmationDialog("Delete this project?", isPresented: $confirmDelete) {
            Button("Delete project and its files", role: .destructive) {
                Task { if await vm.deleteProject() { onDeleted(vm.projectID) } }
            }
        } message: {
            Text("Its chats are kept and move out of the project.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
            TextField("Project name", text: $vm.nameDraft)
                .font(.title.bold())
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .disabled(!vm.draftsLoaded)
                .onSubmit(commitName)
                .onChange(of: nameFocused) { _, focused in
                    if !focused { commitName() }
                }
            Menu {
                Button("Rename") { nameFocused = true }
                Divider()
                Button("Delete Project…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!vm.draftsLoaded)
            .help("Project menu")
            .accessibilityLabel("Project menu")
        }
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.page) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                ChatComposerView(
                    chatVM: chatVM,
                    modelSuggestions: modelSuggestions,
                    maxHeight: maxComposerHeight,
                    placeholder: composerPlaceholder
                )
                if let error = chatVM.errorMessage {
                    Text(error).font(.caption).foregroundStyle(Tone.error)
                }
            }
            chatList
        }
    }

    private var composerPlaceholder: String {
        let name = vm.project?.name ?? ""
        return name.isEmpty ? "New chat in this project…" : "New chat in “\(name)”…"
    }

    private var chatList: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HomeZoneTitle(title: "Chats in this project", detail: "\(vm.chats.count)")
            if vm.chats.isEmpty {
                Text("No chats yet — ask something above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let now = Date()
                VStack(spacing: 0) {
                    ForEach(vm.chats) { chat in
                        Button { onOpenChat(chat.id) } label: {
                            HStack(spacing: Spacing.medium) {
                                Text(chat.displayTitle).lineLimit(1)
                                Spacer(minLength: Spacing.regular)
                                Text(TimeFormatting.shortAge(from: chat.updatedDate, now: now))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .kitRow(isSelected: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Chat: \(chat.displayTitle)")
                    }
                }
            }
        }
    }

    // MARK: - Instructions

    private static let instructionsCaption = "Given to the assistant in every chat of this project."

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack {
                Text("Instructions").font(.subheadline.weight(.semibold))
                Spacer()
                if vm.instructionsEditor == nil, !vm.instructionsDraft.isEmpty {
                    Button("Edit") { vm.beginInstructionsEdit() }
                        .buttonStyle(.kitQuiet)
                        .disabled(!vm.draftsLoaded)
                }
            }
            if vm.instructionsEditor != nil {
                TextEditor(text: Binding(get: { vm.instructionsEditor ?? "" }, set: { vm.instructionsEditor = $0 }))
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(Spacing.small)
                    .background(Surface.text, in: RoundedRectangle(cornerRadius: Radius.control))
                    .accessibilityLabel("Instructions")
                caption(Self.instructionsCaption)
                HStack(spacing: Spacing.regular) {
                    Spacer()
                    Button("Cancel") { vm.cancelInstructionsEdit() }
                        .buttonStyle(.kitQuiet)
                    Button("Save") { Task { await vm.commitInstructionsEdit() } }
                        .buttonStyle(.kitSecondary)
                }
            } else if vm.instructionsDraft.isEmpty {
                Button("Add instructions") { vm.beginInstructionsEdit() }
                    .buttonStyle(.kitQuiet)
                    .disabled(!vm.draftsLoaded)
                caption(Self.instructionsCaption)
            } else {
                Text(vm.instructionsDraft)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: - Knowledge

    private var knowledgeCard: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack {
                Text("Knowledge").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button("Files…", action: pickFiles)
                    Button("Source…") { showSourcePicker = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add knowledge")
                .accessibilityLabel("Add knowledge")
            }
            caption("The assistant looks here first in every chat of this project.")
            if !vm.knowledge.isEmpty {
                VStack(spacing: 0) {
                    ForEach(vm.knowledge) { item in
                        ProjectKnowledgeRow(item: item) { Task { await vm.removeKnowledge(item.id) } }
                    }
                }
            }
            Text("Drop files here")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(Spacing.cozy)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.row).strokeBorder(
                        dropTargeted ? Color.accentColor : Stroke.hairlineColor,
                        style: StrokeStyle(lineWidth: Stroke.selection, dash: [Spacing.small])
                    )
                )
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await vm.addFiles(files) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - Actions

    /// A name typed but never submitted is kept when the page goes away.
    private func commitName() {
        guard vm.draftsLoaded, let project = vm.project, vm.nameDraft != project.name else { return }
        let name = vm.nameDraft
        Task {
            await vm.rename(name)
            onRenamed()
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Add images, PDFs or text files to the project"
        panel.begin { response in
            guard response == .OK else { return }
            Task { await vm.addFiles(panel.urls) }
        }
    }
}

/// One file or pinned source on the Knowledge card: its kind badge, its
/// name, and a remove button shown on hover (always there for VoiceOver).
struct ProjectKnowledgeRow: View {
    let item: ProjectKnowledgeItem
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Chip(text: item.badge, color: Self.tone(item.kind))
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: onRemove) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.kitQuiet)
                .opacity(isHovered ? 1 : 0)
                .help(item.isFile ? "Remove file" : "Unpin")
                .accessibilityLabel(item.isFile ? "Remove \(item.title)" : "Unpin \(item.title)")
        }
        .kitRow(isSelected: false)
        .onHover { isHovered = $0 }
    }

    static func tone(_ kind: ProjectKnowledgeItem.Kind) -> Color {
        switch kind {
        case .jira: Tone.status("blue")
        case .slack: Tone.status("purple")
        case .confluence: Tone.status("teal")
        case .target: Tone.status("green")
        case .track: Tone.warning
        case .pdf, .markdown, .image, .file, .person, .otherSource: Tone.status("gray")
        }
    }
}
