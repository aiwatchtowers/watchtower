import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerCore

/// "Add document…" (#80): the owner picks a .md/.txt file inside the project
/// folder, a kind and optionally a board target. The CLI attaches it and
/// refuses anything outside the folder; the error stays in the sheet.
struct AddProjectDocumentSheet: View {
    @Bindable var vm: ProjectsViewModel
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    /// `fileURL` as the list will show it, computed once when chosen.
    @State private var shownPath = ""
    @State private var kind = "doc"
    @State private var targetID: Int64?
    @State private var targets: [ProjectBoardRow] = []
    @State private var targetsError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a document").font(.headline)
            Text("A .md or .txt file inside \(project.folderPath). Watchtower only lists it — the file is never changed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(fileURL == nil ? "No file chosen" : shownPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(fileURL == nil ? .secondary : .primary)
                Spacer()
                Button("Choose File…", action: chooseFile)
            }
            Picker("Kind", selection: $kind) {
                Text("Spec").tag("spec")
                Text("Plan").tag("plan")
                Text("Doc").tag("doc")
            }
            .pickerStyle(.segmented)
            Picker("Target", selection: $targetID) {
                Text("None").tag(Int64?.none)
                ForEach(targets) { row in
                    Text(String(repeating: "   ", count: row.depth) + row.node.target.text).tag(Optional(Int64(row.node.target.id)))
                }
            }
            if let targetsError {
                Text(targetsError).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let error = vm.attachError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Attach") {
                    guard let fileURL else { return }
                    Task {
                        if await vm.attachDocument(fileURL: fileURL, kind: kind, targetID: targetID) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fileURL == nil || vm.isAttachingDocument)
            }
        }
        .padding(16)
        .frame(width: 420)
        .task {
            vm.clearAttachMessages()
            do {
                targets = try await vm.targetChoices()
            } catch {
                targetsError = "Could not load the board's targets: \(error.localizedDescription)"
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = project.folderURL
        panel.allowedContentTypes = ["md", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        shownPath = relativePath(url)
    }

    /// The chosen file as the owner will see it listed, when it is inside
    /// the folder; the full path otherwise (the CLI then refuses it).
    private func relativePath(_ url: URL) -> String {
        let folder = project.folderURL.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(folder) ? String(path.dropFirst(folder.count)) : path
    }
}
