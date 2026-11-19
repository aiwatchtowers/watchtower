import ChatWire
import SwiftUI
import WatchtowerDesign

/// The `@`/`/` picker's rows over the field while it is open (`ChatUIStyle.pickerList`).
public struct ComposerPickerList: View {
    let items: [ComposerPickerItem]
    let selectedIndex: Int
    let onPick: (Int) -> Void
    @Environment(\.chatUIStyle) private var style

    public init(items: [ComposerPickerItem], selectedIndex: Int, onPick: @escaping (Int) -> Void) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.onPick = onPick
    }

    public var body: some View {
        style.pickerList(items, selected: selectedIndex, onPick: onPick)
            .accessibilityIdentifier("chat.composerPicker")
    }
}

/// One mention or skill chip as `ChatUIStyle.composerChip` draws it, with its remove.
public struct ChatComposerChipContent {
    public let title: String
    public let icon: String
    public let onRemove: () -> Void

    public init(title: String, icon: String, onRemove: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.onRemove = onRemove
    }
}

/// Removable chips for the draft's picked skill and mentions.
public struct ComposerChipsRow: View {
    let mentions: [ChatCompose.Mention]
    var skill: String?
    let onRemoveMention: (ChatCompose.Mention) -> Void
    var onRemoveSkill: () -> Void
    @Environment(\.chatUIStyle) private var style

    public init(
        mentions: [ChatCompose.Mention],
        skill: String?,
        onRemoveMention: @escaping (ChatCompose.Mention) -> Void,
        onRemoveSkill: @escaping () -> Void
    ) {
        self.mentions = mentions
        self.skill = skill
        self.onRemoveMention = onRemoveMention
        self.onRemoveSkill = onRemoveSkill
    }

    public var body: some View {
        if !mentions.isEmpty || skill != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.compact) {
                    if let skill {
                        style.composerChip(ChatComposerChipContent(title: "/" + skill, icon: "wand.and.stars",
                                                                   onRemove: onRemoveSkill))
                    }
                    ForEach(mentions, id: \.self) { mention in
                        style.composerChip(ChatComposerChipContent(
                            title: mention.label, icon: ComposerPickerModel.icon(forKind: mention.kind)
                        ) { onRemoveMention(mention) })
                    }
                }
                .padding(.horizontal, ComposerMetrics.rowInset)
            }
        }
    }
}
