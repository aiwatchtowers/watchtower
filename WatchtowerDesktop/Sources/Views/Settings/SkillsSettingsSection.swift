import SwiftUI
import WatchtowerCore

/// What the skill editor sheet opens on: a blank new file, or an existing one
/// addressed by its filename stem (re-read from disk when the sheet appears,
/// never a snapshot the list happened to be holding).
enum SkillEditorTarget: Identifiable {
    case new
    case existing(String)

    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let name): return "existing:\(name)"
        }
    }
}

/// Settings → Skills card.
///
/// A skill is a markdown file in `<workspace>/skills/` that one of the two AI
/// personas can load on demand during a Discuss chat. Shipped skills arrive
/// with the app and are kept current by the daemon; owner-created ones are
/// plain files this card writes. Everything here is an immediate file write —
/// nothing is staged for the surrounding tab's Save button, which the footer
/// says out loud.
struct SkillsSettingsSection: View {
    @State private var viewModel = SkillsSettingsViewModel()
    @State private var editorTarget: SkillEditorTarget?
    @State private var pendingDeletion: SkillRow?

    var body: some View {
        Section {
            content
            if let error = viewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("New Skill") {
                editorTarget = .new
            }
            .disabled(viewModel.dir == nil)
        } header: {
            Text("Skills")
        } footer: {
            Text(
                "Skills teach the secretary and the assistant how to handle a kind of request — "
                    + "untangling a thread, drafting a status update, breaking a target down. A chat "
                    + "loads one when it fits the ask. Changes here are written to the skill files "
                    + "immediately."
            )
        }
        .onAppear { viewModel.load() }
        .sheet(item: $editorTarget) { target in
            SkillEditorSheet(viewModel: viewModel, target: target)
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "this skill")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Skill", role: .destructive) {
                if let row = pendingDeletion {
                    viewModel.delete(name: row.name)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the skill file. The personas stop seeing it on the next chat.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.dir == nil {
            Text("No active workspace — connect one to author skills.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if viewModel.rows.isEmpty {
            Text("No skills yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(viewModel.rows) { row in
                skillRow(row)
            }
        }
    }

    private func skillRow(_ row: SkillRow) -> some View {
        HStack(alignment: .top) {
            Button {
                editorTarget = .existing(row.name)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.name)
                        badge(Self.personaLabel(row.persona), color: Self.personaColor(row.persona))
                        badge(row.shipped ? "Built-in" : "Custom", color: .secondary)
                    }
                    Text(row.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("Enabled", isOn: Binding(
                get: { row.enabled },
                set: { viewModel.setEnabled(name: row.name, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            // Shipped skills are re-deployed by the daemon, so deleting one
            // would only make it reappear — disabling is their off switch.
            if !row.shipped {
                Button("Delete") {
                    pendingDeletion = row
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    static func personaLabel(_ persona: SkillPersona) -> String {
        switch persona {
        case .secretary: return "Secretary"
        case .assistant: return "Assistant"
        case .both: return "Both"
        }
    }

    static func personaColor(_ persona: SkillPersona) -> Color {
        switch persona {
        case .secretary: return .purple
        case .assistant: return .blue
        case .both: return .teal
        }
    }
}

/// New-skill / edit-skill sheet. The name is the file's identity, so it is
/// editable only while creating; afterwards it is shown read-only (renaming
/// would orphan the Go deploy sidecar's per-name digest bookkeeping).
struct SkillEditorSheet: View {
    let viewModel: SkillsSettingsViewModel
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SkillDraft
    @State private var loadFailed: Bool
    @State private var errorText: String?

    init(viewModel: SkillsSettingsViewModel, target: SkillEditorTarget) {
        self.viewModel = viewModel
        switch target {
        case .new:
            isNew = true
            _draft = State(initialValue: SkillDraft.empty())
            _loadFailed = State(initialValue: false)
        case .existing(let name):
            isNew = false
            // "File missing" and "file present but unparsable" are different
            // states: both refuse to save, and the sheet says so rather than
            // offering a blank editor that Save would flush over real content.
            let loaded = viewModel.draft(for: name)
            _draft = State(
                initialValue: loaded ?? SkillDraft(
                    name: name, description: "", persona: .secretary, body: ""
                )
            )
            _loadFailed = State(initialValue: loaded == nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Skill" : "Edit Skill")
                .font(.headline)

            if loadFailed {
                Text("Could not read this skill file. Fix or remove it on disk, then reopen Settings.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            fields

            Text("Instructions")
                .font(.subheadline)
            TextEditor(text: $draft.body)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .border(Color.secondary.opacity(0.3))

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(loadFailed)
            }
        }
        .padding(16)
        .frame(width: 560, height: 560)
    }

    private var fields: some View {
        Form {
            if isNew {
                TextField("Name", text: $draft.name, prompt: Text("status-update"))
                    .help("Lowercase letters, digits and hyphens. Becomes the filename; it cannot be changed later.")
            } else {
                LabeledContent("Name") {
                    Text(draft.name).foregroundStyle(.secondary)
                }
            }
            TextField(
                "Description",
                text: $draft.description,
                prompt: Text("Use when the owner asks for a status update.")
            )
            .help("One line. This is what the persona reads when deciding whether the skill fits.")
            Picker("Persona", selection: $draft.persona) {
                Text("Secretary").tag(SkillPersona.secretary)
                Text("Assistant").tag(SkillPersona.assistant)
                Text("Both").tag(SkillPersona.both)
            }
        }
        .formStyle(.grouped)
        .frame(height: 130)
    }

    private func save() {
        if viewModel.save(draft, isNew: isNew) {
            errorText = nil
            dismiss()
        } else {
            errorText = viewModel.error
        }
    }
}
