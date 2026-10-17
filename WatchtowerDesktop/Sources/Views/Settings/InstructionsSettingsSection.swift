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
        let stored = state.global.text(field)
        let draft = drafts[field] ?? stored
        let count = OwnerInstructionsState.runeCount(draft)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Text(caption).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { drafts[field] ?? stored }, set: { drafts[field] = $0 }))
                .font(.body)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                Text("\(count) / \(state.limit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(count > state.limit ? .red : .secondary)
                Spacer()
                Button("Save") { Task { await save(field, body: draft) } }
                    .disabled(draft == stored || busy)
            }
            if let error = errors[field] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            suggestionsBlock(field, state: state)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func suggestionsBlock(_ field: InstructionField, state: OwnerInstructionsState) -> some View {
        let rows = state.suggestions.filter { $0.field == field }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("You keep saying this — \(rows.count) suggestion\(rows.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(row.text)”")
                            Text(detail(row)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") { Task { await decide(row, add: true, field: field) } }
                        Button("Dismiss") { Task { await decide(row, add: false, field: field) } }
                    }
                    .disabled(busy)
                }
            }
            .padding(8)
            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        }
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
            // A workbench-scope Add changes that workbench's text, a global one the global text.
            if row.workbenchID == nil { drafts[row.field] = nil }
            errors[field] = nil
        } catch {
            errors[field] = error.localizedDescription
        }
    }
}
