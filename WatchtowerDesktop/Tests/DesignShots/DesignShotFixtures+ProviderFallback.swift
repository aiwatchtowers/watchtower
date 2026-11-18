import AppKit
import ChatUI
import ChatWire
import DesignKit
import SwiftUI
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// Design-only scenes; controls never write settings or start a provider.
@MainActor
enum ProviderFallbackShotFixtures {
    static var shots: [DesignShot] {
        ProviderFallbackPreview.State.allCases.map { state in
            shot(state, pair: .claudeFirst)
        } + [shot(.ready, pair: .codexFirst), shot(.fallback, pair: .codexFirst),
             shot(.recovered, pair: .codexFirst), shot(.bothLimited, pair: .claudeFirst, narrow: true),
             shot(.stopped, pair: .claudeFirst, narrow: true)]
    }

    private static func shot(
        _ state: ProviderFallbackPreview.State, pair: ProviderFallbackPreview.Pair, narrow: Bool = false
    ) -> DesignShot {
        let preview = ProviderFallbackPreview(pair: pair, state: state, nextCheck: "14:30",
                                              chatTitle: "Quarterly planning", modelDescription: "Light: Default · Strong: Default")
        let suffix = pair == .codexFirst ? "-codex" : ""
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
                    Text(preview.preferred.name).font(.headline)
                    modelLine
                }
                SettingsSection(title: ProviderFallbackPreview.reserveLabel) {
                    HStack {
                        Text(preview.reserve.name).font(.headline)
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
            Text(preview.modelDescription).font(.caption)
        }
    }

    private var status: some View {
        ProviderFallbackStatus(copy: preview.copy) {}
    }
}

extension ProviderFallbackShotFixtures {
    static var runtimeShots: [DesignShot] {
        var result: [DesignShot] = []
        for pair in ProviderFallbackPreview.Pair.fixturePairs {
            for narrow in [false, true] {
                for state in [ProviderFallbackPreview.State.fallback, .recovered, .stopped, .pinned] {
                    let name = "provider-chat-\(state.rawValue)-\(pair.preferred.id)\(narrow ? "-narrow" : "")"
                    result.append(DesignShot(name: name, size: NSSize(width: narrow ? 360 : 640, height: 0)) {
                        AnyView(RuntimeProviderChatShot(pair: pair, state: state))
                    })
                }
            }
        }
        return result
    }
}

private struct RuntimeProviderChatShot: View {
    let pair: ProviderFallbackPreview.Pair
    let state: ProviderFallbackPreview.State
    var actualReason = "quota_exhausted"
    private let style = DesignKitChatStyle()
    private static func ignoreAutomatic() {}

    private var model: ChatRoutingPresentation {
        let catalog = AIModelCatalog(providers: ProviderCatalogFixture.providers())
        let actual = state == .pinned ? pair.preferred.id : pair.reserve.id
        let health = try? ChatRoutingStatus.parse(Data("""
            {"preferred_provider":"\(pair.preferred.id)","enabled":true,"revision":"fixture",
             "providers":[{"provider":"\(pair.preferred.id)","state":"\(state == .fallback ? "quota_wait" : "available")"}]}
            """.utf8))
        return ChatRoutingPresentation(pair: pair, automatic: state != .pinned,
                                       actualProvider: state == .pinned ? pair.preferred.id : pair.reserve.id,
                                       actualModel: state == .pinned ? "sample-pinned-model" : "sample-model",
                                       reason: actualReason, health: health, busy: false,
                                       capabilities: catalog.capabilities(for: actual).chatCaps)
    }

    private var preview: ProviderFallbackPreview? {
        state == .stopped ? ProviderFallbackPreview(pair: pair, state: .stopped) : model.preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            Text(ProviderFallbackPreview.chatPolicyLabel).font(.headline)
            Text(preview?.chatPolicyValue ?? model.choice).font(.caption)
            Text(model.actual ?? "").font(.caption).foregroundStyle(.secondary)
            if state == .stopped {
                stoppedRow
            } else if let preview {
                // The shared card and notice, as the composer's routing accessory draws them.
                VStack(alignment: .leading, spacing: Spacing.small) {
                    if let notice = model.nativeToolsNotice { style.routingCaption(notice, warning: true) }
                    style.routingStatusCard(preview.copy, actionEnabled: true,
                                            onAction: state == .pinned ? nil : Self.ignoreAutomatic)
                }
            }
            ChatRoutingPill(label: ChatRoutingModel.label(automatic: state != .pinned, providerName: pair.preferred.name,
                                                          model: state == .pinned ? "sample-pinned-model" : ""),
                            menu: [], enabled: true) { _ in }
                .environment(\.chatUIStyle, style)
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailBackground()
    }

    private var stoppedRow: some View {
        let message = ChatMessageRecord(id: 1, conversationID: 1, role: "assistant",
                                        text: "The draft was saved before the limit was reached.", createdAt: 0,
                                        status: "partial", provider: pair.preferred.id, errorCode: "quota_exhausted")
        let item = ChatThreadItem(message: message, steps: [], siblingIndex: 1, siblingCount: 1)
        var rowActions = ChatRowActions()
        rowActions.allowsRegenerate = false
        var partActions = ChatPartActions()
        partActions.reviewActions = { _ in }
        return ChatUIShotRow.row(item, rowActions: rowActions, partActions: partActions)
    }
}

extension ProviderFallbackShotFixtures {
    static var historicalActualShots: [DesignShot] {
        ProviderFallbackPreview.Pair.fixturePairs.map { pair in
            DesignShot(name: "provider-chat-historical-\(pair.preferred.id)-narrow",
                       size: NSSize(width: 360, height: 0)) {
                AnyView(RuntimeProviderChatShot(pair: pair, state: .recovered, actualReason: "preferred"))
            }
        }
    }
}
