import SwiftUI
import WatchtowerCore

/// Settings → System → Workbench: the owner's two texts (Session instructions,
/// Target procedure) with their "You keep saying this" suggestions. Everything
/// goes through `watchtower instructions … --json`; the texts are not part of
/// config.yaml, so each field has its own Save button.
struct InstructionsSettingsSection: View {
    /// Workbench id → name, for the "only <workbench>" suggestion label.
    let workbenchNames: [Int64: String]

    @State private var state: OwnerInstructionsState?
    @State private var drafts: [InstructionField: String] = [:]
    @State private var errors: [InstructionField: String] = [:]
    @State private var loadError: String?
    @State private var busy = false
    @State private var showPreview = false

    private var cli: WorkbenchCLI? { ProcessCLIRunner.makeDefault().map { WorkbenchCLI(runner: $0) } }

    var body: some View {
        Group {
            if let state {
                fieldBlock(.session, title: "Session instructions",
                           caption: "Every new session in any workbench starts with these. Workbenches can add their own.", state: state)
                fieldBlock(.procedure, title: "Target procedure",
                           caption: "How to work any target. The agent gets it each time it moves a target to In progress.", state: state)
                Button("Preview what the agent gets…") { showPreview = true }
                    .buttonStyle(.link)
            } else if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            }
        }
        .task { await load() }
        .sheet(isPresented: $showPreview) { InstructionsPreviewSheet(workbenchID: nil) }
    }

    private func fieldBlock(_ field: InstructionField, title: String, caption: String, state: OwnerInstructionsState) -> some View {
        InstructionFieldBlock(
            title: title, caption: caption, stored: state.global.text(field), limit: state.limit,
            suggestions: state.suggestions.filter { $0.field == field },
            detail: detail, error: errors[field], busy: busy,
            draft: Binding(get: { drafts[field] }, set: { drafts[field] = $0 }),
            onSave: { body in Task { await save(field, body: body) } },
            onDecide: { row, add in Task { await decide(row, add: add, field: field) } }
        )
    }

    private func detail(_ row: InstructionSuggestion) -> String {
        var text = "\(row.sessionCount) sessions, \(row.workbenchCount) workbenches"
        if let id = row.workbenchID {
            text = "\(row.sessionCount) sessions · only \(workbenchNames[id] ?? "workbench \(id)") → adds to that workbench"
        }
        return text
    }

    private func load() async {
        guard let cli else { loadError = "watchtower binary not found."; return }
        do {
            state = try await cli.instructions(workbenchID: nil)
            loadError = nil
        } catch {
            loadError = "Could not load instructions: \(error.localizedDescription)"
        }
    }

    private func save(_ field: InstructionField, body: String) async {
        guard let cli else { return }
        busy = true
        defer { busy = false }
        do {
            state = try await cli.setInstruction(field: field, workbenchID: nil, body: body)
            drafts[field] = nil
            errors[field] = nil
        } catch {
            errors[field] = error.localizedDescription
        }
    }

    private func decide(_ row: InstructionSuggestion, add: Bool, field: InstructionField) async {
        guard let cli else { return }
        busy = true
        defer { busy = false }
        do {
            state = try await cli.decideSuggestion(id: row.id, add: add)
            // An unsaved draft stays: only a field with no draft follows the new stored text.
            errors[field] = nil
        } catch {
            errors[field] = error.localizedDescription
        }
    }
}
