import AppKit
import GRDB
import SwiftUI
import WatchtowerCore

/// The project page shown in the chat detail area (spec §6.1). Navigation
/// (open a chat, start one, leave after delete) goes through the callbacks:
/// the split view owns the history selection.
struct ProjectDetailView: View {
    @State private var vm: ProjectDetailViewModel
    let dbPool: DatabasePool
    let onNewChat: (Int64) -> Void
    let onOpenChat: (Int64) -> Void
    let onRenamed: () -> Void
    let onDeleted: (Int64) -> Void
    @State private var showSourcePicker = false
    @State private var confirmDelete = false

    init(
        projectID: Int64,
        dbPool: DatabasePool,
        attachmentsRoot: URL?,
        onNewChat: @escaping (Int64) -> Void,
        onOpenChat: @escaping (Int64) -> Void,
        onRenamed: @escaping () -> Void,
        onDeleted: @escaping (Int64) -> Void
    ) {
        _vm = State(initialValue: ProjectDetailViewModel(
            projectID: projectID,
            dbPool: dbPool,
            attachmentsRoot: attachmentsRoot,
            importFile: ProjectDetailViewModel.storeImporter(dbPool: dbPool, rootDir: attachmentsRoot)
        ))
        self.dbPool = dbPool
        self.onNewChat = onNewChat
        self.onOpenChat = onOpenChat
        self.onRenamed = onRenamed
        self.onDeleted = onDeleted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let message = vm.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                TextField("Project name", text: $vm.nameDraft)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .disabled(!vm.draftsLoaded)
                    .onSubmit(commitName)

                section("Instructions", caption: "Given to the assistant in every chat of this project.") {
                    TextEditor(text: Binding(get: { vm.instructionsDraft }, set: { vm.instructionsEdited($0) }))
                        .font(.body)
                        .frame(minHeight: 120)
                        .disabled(!vm.draftsLoaded)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                }

                section("Files", caption: "Text files are read in full; images and PDFs are shown to Claude at the start of each session.") {
                    ForEach(vm.files) { file in
                        HStack {
                            Image(systemName: file.mime.hasPrefix("image/") ? "photo" : "doc")
                            Text(file.name)
                            Spacer()
                            Button { vm.removeFile(file) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove file")
                                .accessibilityLabel("Remove file")
                        }
                    }
                    Button("Add files…", action: pickFiles)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard !urls.isEmpty else { return false }
                    vm.addFiles(urls)
                    return true
                }

                section("Pinned sources", caption: "Where the assistant looks first for this project.") {
                    ForEach(vm.sources) { source in
                        HStack {
                            Text(source.label)
                            Text(source.kind.replacingOccurrences(of: "_", with: " "))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { vm.removeSource(source) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                                .help("Unpin")
                                .accessibilityLabel("Unpin")
                        }
                    }
                    Button("Pin a source…") { showSourcePicker = true }
                }

                section("Chats", caption: nil) {
                    Button("New chat in this project") { onNewChat(vm.projectID) }
                    ForEach(vm.chats) { chat in
                        Button(chat.displayTitle) { onOpenChat(chat.id) }
                            .buttonStyle(.link)
                    }
                }

                Button("Delete project…", role: .destructive) { confirmDelete = true }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { vm.load() }
        .onDisappear {
            commitName()
            Task { await vm.flush() }
        }
        .sheet(isPresented: $showSourcePicker) {
            ProjectSourcePickerSheet(dbPool: dbPool) { vm.addSource($0) }
        }
        .confirmationDialog("Delete this project?", isPresented: $confirmDelete) {
            Button("Delete project and its files", role: .destructive) {
                if vm.deleteProject() { onDeleted(vm.projectID) }
            }
        } message: {
            Text("Its chats are kept and move out of the project.")
        }
    }

    /// A name typed but never submitted is kept when the page goes away.
    private func commitName() {
        guard vm.draftsLoaded, let project = vm.project, vm.nameDraft != project.name else { return }
        vm.rename(vm.nameDraft)
        onRenamed()
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Add images, PDFs or text files to the project"
        panel.begin { response in
            guard response == .OK else { return }
            vm.addFiles(panel.urls)
        }
    }

    private func section<Content: View>(
        _ title: String, caption: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            content()
        }
    }
}
