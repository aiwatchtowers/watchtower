import SwiftUI
import WatchtowerCore

/// The emoji-to-tool dictionary (`reaction_command_map`, migration 00063) the
/// owner drives Watchtower with by reacting to a Slack message. Moved here
/// from Settings → Slack unchanged. It stays editable while the Reaction
/// commands feature is off, so it is ready the moment the owner turns it on.
struct ReactionDictionaryEditor: View {
    let vm: ReactionDictionaryViewModel

    @State private var newReactionEmoji = ""
    @State private var newReactionTool = ReactionDictionaryTools.all[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if vm.mappings.isEmpty {
                Text("No reaction commands configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.mappings) { mapping in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(SlackEmoji.label(forShortcode: mapping.emoji))
                            Text(ReactionToolCatalog.title(for: mapping.tool))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(vm.trustFor(tool: mapping.tool))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("Enabled", isOn: Binding(
                            get: { mapping.enabled },
                            set: { newValue in
                                Task { await vm.setEnabled(emoji: mapping.emoji, enabled: newValue) }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        Button("Remove") {
                            Task { await vm.delete(emoji: mapping.emoji) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }
            }

            if let err = vm.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                TextField("emoji short-name (e.g. white_check_mark)", text: $newReactionEmoji)
                Picker("Tool", selection: $newReactionTool) {
                    ForEach(ReactionDictionaryTools.all, id: \.self) { tool in
                        Text(ReactionToolCatalog.title(for: tool)).tag(tool)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                Button("Add mapping") {
                    let emoji = Self.normalizedEmojiShortName(newReactionEmoji)
                    guard !emoji.isEmpty else { return }
                    Task { await vm.upsert(emoji: emoji, tool: newReactionTool) }
                    newReactionEmoji = ""
                }
                .disabled(Self.normalizedEmojiShortName(newReactionEmoji).isEmpty)
            }
        }
    }

    /// Strips whitespace and surrounding `:` so a pasted `:eyes:` becomes the
    /// bare `eyes` Slack's `reactions.list` actually returns.
    private static func normalizedEmojiShortName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }
}
