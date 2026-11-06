import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore

/// Plan 2026-11-05 Task A2: the composer of a provider that reads no
/// images or PDFs (U1) and the Ollama provider line without the routing
/// card (U3), from the capability rows, on fixture data.
@MainActor
enum ProviderCapabilitiesShotFixtures {
    /// U1 and U3 together, as the main chat shows Ollama: the provider line,
    /// what it lacks, and the paperclip disabled with its reason.
    static func ollamaComposer() -> AnyView {
        let caps = ProviderCapabilities(tools: "watchtower+quick_connections", toolEvents: true, textStream: "token",
                                        usage: "totals", turnCap: "native")
        let presentation = ChatRoutingPresentation(
            preferred: nil, automatic: true, actualProvider: "ollama", actualModel: "llama3.1", reason: nil,
            health: nil, busy: false, actualDisplayName: "Ollama / Local", capabilities: caps)
        return AnyView(VStack(alignment: .leading, spacing: Spacing.small) {
            if let actual = presentation.actual { Text(actual).font(.caption).foregroundStyle(.secondary) }
            if let missing = presentation.missingCapabilities {
                Text(missing).font(.caption).foregroundStyle(.secondary)
            }
            ChatComposerField(text: .constant(""), isStreaming: false, onSend: {}, placeholder: "Ask about your work…",
                              onAttachFiles: { _ in }, attachUnavailableReason: caps.attachUnavailableReason)
        }
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, 12))
    }
}
