import SwiftUI
import WatchtowerCore

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
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = config.parseError {
                errorRow("Parse error: \(error)")
            }
            if let error = saveError {
                errorRow(error)
            }
            ProviderRoutingApplicationStatus(model: config.routingApplication) {
                Task { await config.applySavedRouting() }
            }
            HStack {
                Button("Open in Editor") { config.openInEditor() }
                Button("Reveal in Finder") { config.revealInFinder() }
                Spacer()
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
                .buttonStyle(.kitPrimary)
                .disabled(isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, Spacing.regular)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func errorRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Tone.error)
            .lineLimit(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, Spacing.small)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await config.saveAndApply(extraSave: extraSave)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// The actual saved/applying/applied/error presentation shared by Settings and
/// design-shot fixtures. Retry applies current saved state through its owner.
struct ProviderRoutingApplicationStatus: View {
    let model: ProviderRoutingApplication
    var retry: () -> Void

    var body: some View {
        if let copy = model.copy {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(copy.title).font(.caption).foregroundStyle(copy.emphasis == .error ? Tone.error : Color.secondary)
                    Text(copy.detail).font(.caption).foregroundStyle(Color.secondary)
                    if let text = model.confirmationText {
                        Text(text).font(.caption).foregroundStyle(Color.secondary)
                    }
                    if let diagnostic = model.diagnostic {
                        Text(diagnostic).font(.caption).foregroundStyle(Tone.error).textSelection(.enabled)
                    }
                    if let action = copy.action {
                        Button(action, action: retry).buttonStyle(.kitSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, Spacing.regular)
            }
    }
}
