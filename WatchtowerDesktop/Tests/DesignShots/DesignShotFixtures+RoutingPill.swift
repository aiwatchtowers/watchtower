import AppKit
import ChatUI
import ChatWire
import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The main chat's routing accessory and the code questions' pill, state by state (#1822 T17): rendered before and
/// after the pill moved into `ChatUI`, so the two renders can be compared name by name. Synthetic data only.
@MainActor
enum RoutingPillShotFixtures {
    static var shots: [DesignShot] {
        let wide = NSSize(width: 560, height: 0)
        return [
            DesignShot(name: "routing-pill-auto", size: wide) { accessory(Scene()) },
            DesignShot(name: "routing-pill-pinned-model", size: wide) {
                accessory(Scene(automatic: false, provider: "codex", model: "gpt-5.6-sol"))
            },
            DesignShot(name: "routing-pill-pinned-auto-model", size: wide) {
                accessory(Scene(automatic: false, provider: "codex"))
            },
            DesignShot(name: "routing-pill-busy", size: wide) { accessory(Scene(busy: true)) },
            DesignShot(name: "routing-actual-line", size: wide) {
                accessory(Scene(actual: "claude", actualModel: "sample-model"))
            },
            DesignShot(name: "routing-preview-unsupported", size: wide) {
                accessory(Scene(actual: "claude", actualModel: "sample-model", reason: "required_capability_missing"))
            },
            DesignShot(name: "routing-preview-recovered-busy", size: wide) {
                accessory(Scene(actual: "codex", actualModel: "sample-model", reason: "quota_exhausted",
                                preferredState: "available", busy: true))
            },
            DesignShot(name: "routing-native-tools-notice", size: wide) {
                accessory(Scene(actual: "codex", actualModel: "sample-model", reason: "quota_exhausted",
                                preferredState: "quota_wait"))
            },
            DesignShot(name: "routing-status-error", size: wide) {
                accessory(Scene(statusError: "Couldn't read provider availability: The file couldn’t be opened."))
            },
            DesignShot(name: "routing-catalog-unread", size: wide) { accessory(Scene(catalogRead: false)) },
            DesignShot(name: "routing-accessory-narrow", size: NSSize(width: 360, height: 0)) {
                accessory(Scene(actual: "codex", actualModel: "sample-model", reason: "quota_exhausted",
                                preferredState: "available"))
            },
            DesignShot(name: "routing-pill-code-question", size: NSSize(width: 460, height: 0)) { codeQuestionHeader() },
            DesignShot(name: "routing-pill-questions-view", size: NSSize(width: 420, height: 0)) { questionsHeader() }
        ]
    }

    /// One accessory state: the chat's pick, what the feed says runs it, the availability read.
    struct Scene {
        var automatic = true
        var provider = "claude"
        var model = ""
        var actual = ""
        var actualModel = ""
        var reason = ""
        /// The preferred provider's availability ("" = no status read).
        var preferredState = ""
        var statusError: String?
        var catalogRead = true
        var busy = false
    }

    private static var catalog: AIModelCatalog { AIModelCatalog(providers: ProviderCatalogFixture.providers()) }

    private static func status(_ scene: Scene) -> ChatRoutingStatus? {
        guard !scene.preferredState.isEmpty else { return nil }
        return try? ChatRoutingStatus.parse(Data("""
            {"preferred_provider":"claude","enabled":true,"revision":"fixture",
             "providers":[{"provider":"claude","state":"\(scene.preferredState)","next_probe_at":"2026-01-02T14:30:00Z"}]}
            """.utf8))
    }

    // MARK: - Today's views (base)

    private static func accessory(_ scene: Scene) -> AnyView {
        ProviderCatalogFixture.seedShared()
        let catalog = scene.catalogRead ? catalog : AIModelCatalog(providers: [])
        let preferred = scene.automatic ? "claude" : scene.provider
        let presentation = ChatRoutingPresentation(
            pair: catalog.fallbackPair(preferred: preferred), automatic: scene.automatic,
            actualProvider: scene.actual.isEmpty ? nil : scene.actual,
            actualModel: scene.actualModel.isEmpty ? nil : scene.actualModel,
            reason: scene.reason, health: status(scene), busy: scene.busy,
            actualDisplayName: scene.actual.isEmpty ? nil : catalog.provider(scene.actual)?.displayName,
            capabilities: scene.catalogRead ? catalog.capabilities(for: scene.actual.isEmpty ? preferred : scene.actual) : nil
        )
        return AnyView(TodayAccessory(presentation: presentation, error: scene.statusError, busy: scene.busy,
                                      provider: AIProvider(rawValue: scene.provider) ?? .claude, model: scene.model,
                                      automatic: scene.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.vertical, Spacing.medium)
            .detailBackground())
    }

    private static func codeQuestionHeader() -> AnyView {
        ProviderCatalogFixture.seedShared()
        return AnyView(HStack(spacing: 6) {
            Image(systemName: "sparkle").foregroundStyle(.orange)
            Text("SessionStore.swift:42").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            ChatModelPicker(provider: .claude, model: "", suggestions: [], onSelectProvider: { _ in }, onSelectModel: { _ in })
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    private static func questionsHeader() -> AnyView {
        ProviderCatalogFixture.seedShared()
        return AnyView(HStack {
            Image(systemName: "chevron.left")
            Text("Code viewer · SessionStore.swift").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            ChatModelPicker(provider: .codex, model: "gpt-5.6-sol", suggestions: [],
                            onSelectProvider: { _ in }, onSelectModel: { _ in })
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }
}

/// Today's `ChatComposerAccessory` body over fixed data (the real one reads a live `ChatViewModel`).
private struct TodayAccessory: View {
    let presentation: ChatRoutingPresentation
    let error: String?
    let busy: Bool
    let provider: AIProvider
    let model: String
    let automatic: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let actual = presentation.actual { Text(actual).font(.caption).foregroundStyle(.secondary) }
                if let missing = presentation.missingCapabilities {
                    Text(missing).font(.caption).foregroundStyle(.secondary)
                }
                if let preview = presentation.preview {
                    ChatRoutingStatusView(preview: preview, nativeToolsNotice: presentation.nativeToolsNotice,
                                          actionEnabled: !busy,
                                          onAction: preview.state == .recovered ? {} : nil)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(Tone.warning)
                }
            }
            .padding(.horizontal, Spacing.large)
            ChatModelPicker(provider: provider, model: model, suggestions: [], onSelectProvider: { _ in },
                            onSelectModel: { _ in }, automatic: automatic, onSelectAutomatic: {})
                .disabled(busy)
                .padding(.horizontal, Spacing.large).padding(.bottom, Spacing.compact)
        }
    }
}
