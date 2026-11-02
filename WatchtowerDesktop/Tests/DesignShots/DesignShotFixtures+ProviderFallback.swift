import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore

/// Design-only scenes; controls never write settings or start a provider.
@MainActor
enum ProviderFallbackShotFixtures {
    static var shots: [DesignShot] {
        ProviderFallbackPreview.State.allCases.map { state in
            shot(state, preferred: .claude)
        } + [shot(.ready, preferred: .codex), shot(.fallback, preferred: .codex),
             shot(.recovered, preferred: .codex), shot(.bothLimited, preferred: .claude, narrow: true),
             shot(.stopped, preferred: .claude, narrow: true)]
    }

    private static func shot(
        _ state: ProviderFallbackPreview.State, preferred: ProviderFallbackPreview.Provider, narrow: Bool = false
    ) -> DesignShot {
        let preview = ProviderFallbackPreview(preferred: preferred, state: state)
        let suffix = preferred == .codex ? "-codex" : ""
        return DesignShot(name: "provider-fallback-\(state.rawValue)\(suffix)\(narrow ? "-narrow" : "")",
                          size: NSSize(width: narrow ? 360 : 640, height: 0)) {
            AnyView(ProviderFallbackPreviewView(preview: preview))
        }
    }
}

private struct ProviderFallbackPreviewView: View {
    let preview: ProviderFallbackPreview

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(preview.pageSubtitle).font(.caption).foregroundStyle(.secondary)
                Text(preview.pageTitle).font(.title2.weight(.semibold))
            }
            if preview.isChat {
                SettingsSection(title: ProviderFallbackPreview.chatPolicyLabel) {
                    Text(preview.chatPolicyValue)
                    Text(preview.actualLabel).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                SettingsSection(title: ProviderFallbackPreview.preferredLabel) {
                    Text(preview.preferred.rawValue).font(.headline)
                    modelLine
                }
                SettingsSection(title: ProviderFallbackPreview.reserveLabel) {
                    HStack {
                        Text(preview.reserve.rawValue).font(.headline)
                        Spacer()
                        Text(preview.connectionLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    if preview.enabled { modelLine }
                    Toggle(ProviderFallbackPreview.automaticLabel, isOn: .constant(preview.enabled))
                        .toggleStyle(.switch)
                        .disabled(!preview.enabled || preview.copy.busy)
                }
            }
            status
            if !preview.isChat {
                Text(ProviderFallbackPreview.recovery).font(.caption).foregroundStyle(.secondary)
                Text(ProviderFallbackPreview.scope).font(.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private var modelLine: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(ProviderFallbackPreview.modelsLabel).font(.caption).foregroundStyle(.secondary)
            Text(ProviderFallbackPreview.modelsValue).font(.caption)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(preview.copy.title).font(.headline).foregroundStyle(tone)
            Text(preview.copy.detail).font(.body).fixedSize(horizontal: false, vertical: true)
            if preview.copy.busy {
                ProgressView().controlSize(.small).accessibilityLabel(preview.copy.title)
            }
            if let action = preview.copy.action {
                Button(action) {}.buttonStyle(.kitPrimary)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container))
    }

    private var tone: Color {
        switch preview.copy.emphasis {
        case .neutral: .secondary
        case .success: Tone.success
        case .warning: Tone.warning
        case .error: Tone.error
        }
    }
}
