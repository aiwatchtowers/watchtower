import SwiftUI
import WatchtowerCore

/// General tab — app-wide preferences that belong to no single feature:
/// the assistant language (`digest.language`).
struct GeneralSettings: View {
    @Bindable var config: ConfigService

    var body: some View {
        Form {
            Section("Assistant") {
                AssistantLanguageField(selection: Binding(
                    // Absent key = what the Go pipelines use, not the macOS
                    // default: only onboarding writes that one.
                    get: { config.digestLanguage ?? AssistantLanguageCatalog.fallbackName },
                    set: { config.digestLanguage = $0 }
                ))
                Text(AssistantLanguageText.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .safeAreaInset(edge: .bottom) { ConfigSaveBar(config: config) }
    }
}
