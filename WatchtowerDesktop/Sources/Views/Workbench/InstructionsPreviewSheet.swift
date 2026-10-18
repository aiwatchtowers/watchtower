import SwiftUI
import WatchtowerCore

/// Read-only: the exact brief slot and target procedure the agent receives
/// (`watchtower instructions preview --json`). `workbenchID` nil previews the
/// global texts alone.
struct InstructionsPreviewSheet: View {
    let workbenchID: Int64?
    @Environment(\.dismiss) private var dismiss
    @State private var preview: (briefSlot: String, procedure: String)?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What the agent gets").font(.headline)
            if let preview {
                section("In the session brief", text: preview.briefSlot)
                section("When a target goes In progress", text: preview.procedure)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                ProgressView()
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .task { await load() }
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text.isEmpty ? "Nothing — no text is set." : text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func load() async {
        guard let runner = ProcessCLIRunner.makeDefault() else { error = "watchtower binary not found."; return }
        do {
            preview = try await WorkbenchCLI(runner: runner).instructionsPreview(workbenchID: workbenchID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
