import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

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
        let preview = ProviderFallbackPreview(preferred: preferred, state: state, nextCheck: "14:30")
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

extension ProviderFallbackShotFixtures {
    static var runtimeShots: [DesignShot] {
        var result: [DesignShot] = []
        for preferred in ProviderFallbackPreview.Provider.allCases {
            for narrow in [false, true] {
                for state in [ProviderFallbackPreview.State.recovered, .stopped, .pinned] {
                    let name = "provider-chat-\(state.rawValue)-\(preferred.rawValue.lowercased())\(narrow ? "-narrow" : "")"
                    result.append(DesignShot(name: name, size: NSSize(width: narrow ? 360 : 640, height: 0)) {
                        AnyView(RuntimeProviderChatShot(preferred: preferred, state: state))
                    })
                }
            }
        }
        return result
    }
}

private struct RuntimeProviderChatShot: View {
    let preferred: ProviderFallbackPreview.Provider
    let state: ProviderFallbackPreview.State
    var actualReason = "quota_exhausted"
    private static func ignoreAutomatic() {}

    private var model: ChatRoutingPresentation {
        let health = try? ChatRoutingStatus.parse(Data("""
            {"preferred_provider":"\(preferred.rawValue.lowercased())","enabled":true,"revision":"fixture",
             "providers":[{"provider":"\(preferred.rawValue.lowercased())","state":"available"}]}
            """.utf8))
        return ChatRoutingPresentation(preferred: preferred, automatic: state != .pinned,
                                       actualProvider: state == .pinned ? preferred.rawValue.lowercased() : preferred.other.rawValue.lowercased(),
                                       actualModel: state == .pinned ? "sample-pinned-model" : "sample-model",
                                       reason: actualReason, health: health, busy: false)
    }

    private var preview: ProviderFallbackPreview? {
        state == .stopped ? ProviderFallbackPreview(preferred: preferred, state: .stopped) : model.preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            Text(ProviderFallbackPreview.chatPolicyLabel).font(.headline)
            Text(preview?.chatPolicyValue ?? model.choice).font(.caption)
            Text(model.actual ?? "").font(.caption).foregroundStyle(.secondary)
            if state == .stopped {
                stoppedRow
            } else if let preview {
                ChatRoutingStatusView(preview: preview, onAction: state == .pinned ? nil : Self.ignoreAutomatic)
            }
            ChatModelPicker(provider: preferred == .claude ? .claude : .codex,
                            model: state == .pinned ? "sample-pinned-model" : "", suggestions: [],
                            onSelectProvider: { _ in }, onSelectModel: { _ in },
                            automatic: state != .pinned, onSelectAutomatic: Self.ignoreAutomatic)
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailBackground()
    }

    private var stoppedRow: some View {
        let message = ChatMessageRecord(id: 1, conversationID: 1, role: "assistant",
                                        text: "The draft was saved before the limit was reached.", createdAt: 0,
                                        status: "partial", provider: preferred.rawValue.lowercased(), errorCode: "quota_exhausted")
        let item = ChatThreadItem(message: message, steps: [], siblingIndex: 1, siblingCount: 1)
        return ChatMessageRow(item: item, isLast: true, isEditing: false,
                              actions: ChatRowActions(regenerate: nil, retry: nil, reviewActions: { _ in }, continueStopped: nil))
    }
}

extension ProviderFallbackShotFixtures {
    static var historicalActualShots: [DesignShot] {
        ProviderFallbackPreview.Provider.allCases.map { preferred in
            DesignShot(name: "provider-chat-historical-\(preferred.rawValue.lowercased())-narrow",
                       size: NSSize(width: 360, height: 0)) {
                AnyView(RuntimeProviderChatShot(preferred: preferred, state: .recovered, actualReason: "preferred"))
            }
        }
    }
}
