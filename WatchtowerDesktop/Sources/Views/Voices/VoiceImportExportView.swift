import AppKit
import SwiftUI
import WatchtowerCore

/// Export/Import sheets for the Voices window's Review screen (design spec
/// §5, Task 15). Every write goes through `VoiceRegistryCenter` — these
/// sheets are pure UI over `export`/`previewImport`/`applyImport`.

/// "Export voice prints": a people checklist (default all, owner included —
/// deselectable), a password + confirmation, then an `NSSavePanel` for the
/// destination. The password never leaves this sheet except inside the
/// encrypted file.
struct VoiceExportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let people: [VoicePersonSummary]

    @State private var selected: Set<Int64>
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isExporting = false
    @State private var errorMessage: String?

    init(people: [VoicePersonSummary]) {
        self.people = people
        _selected = State(initialValue: Set(people.map(\.id)))
    }

    private var center: VoiceRegistryCenter { appState.voiceRegistryCenter }

    private var canExport: Bool {
        !selected.isEmpty && !password.isEmpty && password == confirmPassword && !isExporting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export voice prints").font(.headline)
            Text("Sends embeddings only — never audio or transcript text. The file is encrypted; share the password with the recipient separately.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if people.isEmpty {
                Text("No registry people to export").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(people) { person in
                            Toggle(person.displayName, isOn: toggleBinding(person.id))
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            SecureField("Password", text: $password)
            SecureField("Confirm password", text: $confirmPassword)
            if !confirmPassword.isEmpty && password != confirmPassword {
                Text("Passwords don't match").font(.caption).foregroundStyle(.red)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") { beginExport() }
                    .disabled(!canExport)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func toggleBinding(_ id: Int64) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { isOn in
            if isOn { selected.insert(id) } else { selected.remove(id) }
        })
    }

    private func beginExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voices.wtvoices"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isExporting = true
            Task {
                do {
                    try await center.export(to: url, password: password, personIDs: selected)
                    isExporting = false
                    dismiss()
                } catch {
                    isExporting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// "Import voice prints": pick a `.wtvoices` file, enter the password,
/// preview what it would do, then commit. Import stays disabled while the
/// preview flags a model mismatch or a duplicate file — there is nothing
/// useful `applyImport()` could do with either.
struct VoiceImportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var fileURL: URL?
    @State private var password = ""
    @State private var preview: VoiceImportPreview?
    @State private var isBusy = false
    @State private var errorMessage: String?

    private var center: VoiceRegistryCenter { appState.voiceRegistryCenter }

    private var canImport: Bool {
        guard let preview else { return false }
        return !preview.modelMismatch && !preview.alreadyImported && !isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import voice prints").font(.headline)

            HStack {
                Text(fileURL?.lastPathComponent ?? "No file chosen")
                    .foregroundStyle(fileURL == nil ? .secondary : .primary)
                Spacer()
                Button("Choose File…") { chooseFile() }
            }

            SecureField("Password", text: $password)

            Button("Preview") { Task { await runPreview() } }
                .disabled(fileURL == nil || password.isEmpty || isBusy)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            if let preview {
                previewSummary(preview)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") { Task { await runApply() } }
                    .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { center.discardPendingImport() }
    }

    @ViewBuilder
    private func previewSummary(_ preview: VoiceImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("From \(preview.sender.name)").fontWeight(.semibold)
            if preview.modelMismatch {
                Text("This file was made with a different voice model and can't be imported.")
                    .foregroundStyle(.red)
            } else if preview.alreadyImported {
                Text("This file was already imported.").foregroundStyle(.secondary)
            } else {
                Text("\(preview.people) people · \(preview.samples) samples")
                if !preview.merges.isEmpty {
                    Text("Merges into: \(preview.merges.joined(separator: ", "))")
                }
                if !preview.newPeople.isEmpty {
                    Text("New: \(preview.newPeople.joined(separator: ", "))")
                }
                if !preview.conflicts.isEmpty {
                    Text(preview.conflicts.joined(separator: "\n")).foregroundStyle(.orange)
                }
                if preview.skippedOwner > 0 {
                    Text("\(preview.skippedOwner) skipped (that's you)").foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a .wtvoices file"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            fileURL = url
            preview = nil
            errorMessage = nil
            center.discardPendingImport()
        }
    }

    private func runPreview() async {
        guard let fileURL else { return }
        isBusy = true
        errorMessage = nil
        do {
            preview = try await center.previewImport(url: fileURL, password: password)
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func runApply() async {
        isBusy = true
        errorMessage = nil
        do {
            try await center.applyImport()
            isBusy = false
            dismiss()
        } catch {
            isBusy = false
            errorMessage = error.localizedDescription
        }
    }
}
