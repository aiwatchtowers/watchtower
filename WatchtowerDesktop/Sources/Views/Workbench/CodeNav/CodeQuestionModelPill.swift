import ChatUI
import SwiftUI
import WatchtowerCore

/// The code questions' provider/model pill (spec 2026-10-02 §9.1): ChatUI's routing pill, the main chat's look and
/// menu with no automatic choice. A pick goes to `onPick`; the question's center stores it.
struct CodeQuestionModelPill: View {
    let choice: CodeQuestionSurface.ModelChoice
    let suggestions: [String]
    let enabled: Bool
    let onPick: (CodeQuestionSurface.ModelChoice) -> Void

    var body: some View {
        ChatRoutingPill(
            label: ChatRoutingModel.label(automatic: false, providerName: choice.provider.displayName, model: choice.model),
            menu: ChatRoutingModel.menu(
                automatic: false,
                providers: AIProvider.offered(by: .shared, current: choice.provider).map { ($0.rawValue, $0.displayName) },
                models: suggestions
            ),
            enabled: enabled
        ) { item in
            switch item.pick {
            case .provider(let id):
                if let provider = AIProvider(rawValue: id) { onPick(choice.switching(to: provider)) }
            case .model(let model):
                onPick(.init(provider: choice.provider, model: model))
            case .automatic:
                break
            }
        }
        .environment(\.chatUIStyle, DesignKitChatStyle())
    }
}
