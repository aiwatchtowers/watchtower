import SwiftUI
import WatchtowerCore

/// Spec §3.6: greeting + four work prompts. Replaces the Welcome chat.
struct ChatEmptyState: View {
    let ownerName: String
    let onPrompt: (ChatStarterPrompt) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(greeting).font(.title2).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(ChatStarterPrompt.all) { prompt in
                    Button(prompt.title) { onPrompt(prompt) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 520)
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity)
    }

    private var greeting: String {
        let first = ownerName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "What can I help with?" : "What can I help with, \(first)?"
    }
}
