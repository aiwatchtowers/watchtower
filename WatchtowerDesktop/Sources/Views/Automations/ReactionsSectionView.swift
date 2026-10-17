import SwiftUI
import WatchtowerCore

/// "Reactions aren't being read" with **Turn on**: the Inbox strip's path
/// (`featureManager.enableNow` + daemon restart). Renders nothing unless the
/// `reaction-commands` feature is known to be off.
struct ReactionCommandsOffNote: View {
    let text: String
    @Environment(AppState.self) private var appState

    private var isOff: Bool {
        ReactionCheatSheetView.FeatureState.from(features: appState.featureManager.features, lastCheck: nil) == .off
    }

    var body: some View {
        if isOff {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.callout)
                Spacer()
                Button("Turn on") { turnOn() }
                    .disabled(appState.featureManager.isApplying)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func turnOn() {
        let manager = appState.featureManager
        Task {
            await manager.enableNow(ReactionCheatSheetView.reactionCommandsFeatureID) {
                try await DaemonManager.restart()
            }
        }
    }
}

/// Automations → Reactions: the dictionary editor, the recipes that listen to
/// reactions, and **New reaction automation**.
struct ReactionsSectionView: View {
    @Environment(AppState.self) private var appState
    let items: [AutomationListItem]
    var onOpenAutomation: (Int64) -> Void
    var onNew: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReactionCommandsOffNote(text: "Reactions aren't being read. Turn on Reaction commands")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Reaction commands").font(.headline)
                    Text("React to a Slack message with an emoji to run a tool on it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let vm = appState.reactionDictionaryViewModel {
                        ReactionDictionaryEditor(vm: vm)
                    } else {
                        Text("Loading...").font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Automations that listen to reactions").font(.headline)
                        Spacer()
                        Button("New reaction automation") { onNew?() }
                            .disabled(onNew == nil)
                    }
                    let rows = ReactionAutomationRows.rows(from: items)
                    if rows.isEmpty {
                        Text("No automation listens to reactions yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        Button { onOpenAutomation(row.id) } label: {
                            HStack {
                                Text(row.name)
                                Spacer()
                                Text(row.emoji.map { SlackEmoji.label(forShortcode: $0) } ?? "any emoji")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { appState.reactionDictionaryViewModel?.refresh() }
    }
}
