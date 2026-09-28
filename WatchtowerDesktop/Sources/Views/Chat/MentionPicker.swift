import SwiftUI
import WatchtowerCore

/// The @/`/` picker list shown above the composer while open.
struct ComposerPickerList: View {
    let items: [ComposerPickerItem]
    let selectedIndex: Int
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { onPick(index) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon).frame(width: 18)
                        Text(item.title).lineLimit(1)
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(index == selectedIndex ? Color.accentColor.opacity(0.18) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separatorColor)))
        .padding(.horizontal, 12)
    }
}

/// Removable chips for the draft's picked mentions (and, from Task 26, its skill).
struct ComposerChipsRow: View {
    let mentions: [MentionCandidate]
    var skill: String?
    let onRemoveMention: (MentionCandidate) -> Void
    var onRemoveSkill: (() -> Void)?

    var body: some View {
        if !mentions.isEmpty || skill != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let skill {
                        chip("/" + skill, icon: "wand.and.stars") { onRemoveSkill?() }
                    }
                    ForEach(mentions) { mention in
                        chip(mention.label, icon: ComposerPickerModel.item(for: mention).icon) { onRemoveMention(mention) }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func chip(_ title: String, icon: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(title).lineLimit(1)
            Button(action: onRemove) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Remove \(title)")
                .accessibilityLabel("Remove \(title)")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }
}
