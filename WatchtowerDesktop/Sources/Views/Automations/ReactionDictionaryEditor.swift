import SwiftUI
import WatchtowerCore

/// The emoji-to-tool dictionary (`reaction_command_map`, migration 00063) the
/// owner drives Watchtower with by reacting to a Slack message, embedded in
/// the Reactions built-in's card under **When** (C3; ask #366 kept one
/// editor). Each row's tool, on/off and Remove edit in place; **+** opens an
/// inline row for a new emoji. It stays editable while the built-in is off,
/// so it is ready the moment the owner turns it on.
struct ReactionDictionaryEditor: View {
    let vm: ReactionDictionaryViewModel
    /// The parameter's label (`show`'s "Reactions").
    var title = "Reactions"

    @State private var adding = false
    @State private var newReactionEmoji = ""
    @State private var newReactionTool = ReactionDictionaryTools.all[0]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.kitIcon(isOn: adding))
                .help("Add a reaction")
                .accessibilityLabel("Add a reaction")
            }
            if vm.mappings.isEmpty, !adding {
                Text("No reaction commands configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(vm.mappings) { mapping in
                row(mapping)
            }
            if adding {
                addRow
            }
            if let err = vm.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
            }
        }
        .controlSize(.small)
        .task { await vm.refreshAsync() }
    }

    private func row(_ mapping: ReactionCommandMapping) -> some View {
        HStack(spacing: Spacing.regular) {
            Text(SlackEmoji.label(forShortcode: mapping.emoji))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180, alignment: .leading)
            toolPicker(selection: Binding(
                get: { mapping.tool },
                set: { tool in Task { await vm.upsert(emoji: mapping.emoji, tool: tool) } }
            ))
            Spacer()
            Text(vm.trustFor(tool: mapping.tool))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Enabled", isOn: Binding(
                get: { mapping.enabled },
                set: { newValue in Task { await vm.setEnabled(emoji: mapping.emoji, enabled: newValue) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
            Button("Remove") {
                Task { await vm.delete(emoji: mapping.emoji) }
            }
            .buttonStyle(.kitQuiet)
        }
        .padding(.vertical, Spacing.tight)
    }

    /// The **+** row: an emoji short-name and its tool, inline (no pop-up).
    private var addRow: some View {
        HStack(spacing: Spacing.regular) {
            TextField("emoji short-name (e.g. white_check_mark)", text: $newReactionEmoji)
                .textFieldStyle(.kit)
            toolPicker(selection: $newReactionTool)
            Button("Add") {
                let emoji = Self.normalizedEmojiShortName(newReactionEmoji)
                guard !emoji.isEmpty else { return }
                let tool = newReactionTool
                Task { await vm.upsert(emoji: emoji, tool: tool) }
                newReactionEmoji = ""
                adding = false
            }
            .buttonStyle(.kitSecondary)
            .disabled(Self.normalizedEmojiShortName(newReactionEmoji).isEmpty)
            Button("Cancel") {
                newReactionEmoji = ""
                adding = false
            }
            .buttonStyle(.kitQuiet)
        }
        .padding(Spacing.regular)
        .card()
    }

    private func toolPicker(selection: Binding<String>) -> some View {
        // A row's tool the list no longer offers still shows as itself.
        let tools = ReactionDictionaryTools.all.contains(selection.wrappedValue)
            ? ReactionDictionaryTools.all : ReactionDictionaryTools.all + [selection.wrappedValue]
        return Picker("Tool", selection: selection) {
            ForEach(tools, id: \.self) { tool in
                Text(ReactionToolCatalog.reactionTitle(for: tool)).tag(tool)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Strips whitespace and surrounding `:` so a pasted `:eyes:` becomes the
    /// bare `eyes` Slack's `reactions.list` actually returns.
    static func normalizedEmojiShortName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }
}
