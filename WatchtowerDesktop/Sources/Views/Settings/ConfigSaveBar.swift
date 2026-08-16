import SwiftUI

/// Shared bottom bar for Settings tabs that edit config.yaml. Owns the
/// transient save/parse error display so every tab that saves shows errors
/// the same way. The ConfigService instance is shared by SettingsView so all
/// tabs edit one in-memory config.
struct ConfigSaveBar: View {
    @Bindable var config: ConfigService
    /// Runs after `config.save()` succeeds, before the "Saved" confirmation
    /// — e.g. `FeaturesSettings` uses this to replay the Feature Manager's
    /// staged CLI changes and restart the daemon as part of the same Save
    /// action, so a tab with a manager section gets one combined save
    /// instead of a second, separate control.
    var extraSave: (() async throws -> Void)?
    @State private var saveError: String?
    @State private var showSaved = false
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let error = config.parseError {
                errorRow("Parse error: \(error)")
            }
            if let error = saveError {
                errorRow(error)
            }
            HStack {
                Button("Open in Editor") { config.openInEditor() }
                Button("Reveal in Finder") { config.revealInFinder() }
                Spacer()
                if showSaved {
                    Text("Saved").foregroundStyle(.green).transition(.opacity)
                }
                Button("Reload") {
                    config.reload()
                    saveError = nil
                }
                .disabled(isSaving)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func errorRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 6)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try config.save()
            try await extraSave?()
            saveError = nil
            withAnimation { showSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { showSaved = false }
            }
        } catch {
            saveError = error.localizedDescription
        }
    }
}
