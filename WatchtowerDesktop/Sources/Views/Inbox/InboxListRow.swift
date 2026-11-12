import SwiftUI
import WatchtowerCore

/// One row of the Inbox list (spec "The list", mockup): the kind's tile,
/// the title with the unread dot before it, the first real line of content
/// under it, a quiet meta line, and on the right the time above the count.
/// A row with a ⋯ of its own (the Idea finder) shows it over its trailing
/// edge on hover or focus, by opacity, so the row never changes height.
struct InboxListRow: View {
    let content: InboxRowContent
    let isSelected: Bool
    /// The row's own ⋯ (and context menu); empty draws none.
    var menu: [InboxMenuEntry] = []
    /// The context menu when the row has no ⋯ of its own (an artifact's ⋯).
    var contextEntries: [InboxMenuEntry] = []
    /// A press in the row's ⋯ or its context menu.
    var onMenu: (InboxMenuCommand) -> Void = { _ in }

    @State private var isHovered = false
    @FocusState private var menuFocused: Bool

    init(
        content: InboxRowContent,
        isSelected: Bool,
        menu: [InboxMenuEntry] = [],
        contextEntries: [InboxMenuEntry] = [],
        onMenu: @escaping (InboxMenuCommand) -> Void = { _ in }
    ) {
        self.content = content
        self.isSelected = isSelected
        self.menu = menu
        self.contextEntries = contextEntries
        self.onMenu = onMenu
    }

    /// The ⋯ is on screen: under the pointer, focused, or on the selected row.
    private var showsMenu: Bool { !menu.isEmpty && (isHovered || menuFocused || isSelected) }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            InboxTile(kind: content.kind, symbol: content.symbol, isSelected: isSelected)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    if content.isUnread {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                            .accessibilityIdentifier("inbox.row.unread")
                    }
                    Text(content.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                }
                if !content.preview.isEmpty {
                    Text(content.preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !content.meta.isEmpty {
                    Text(content.meta)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.small)
            VStack(alignment: .trailing, spacing: Spacing.compact) {
                if !content.time.isEmpty {
                    Text(content.time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        // The ⋯ takes the time's place while it shows.
                        .opacity(showsMenu ? 0 : 1)
                }
                if let pill = content.pill {
                    InboxRowPillView(pill: pill)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(content))
        .accessibilityValue(content.isUnread ? "Unread" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            if !menu.isEmpty {
                InboxMoreMenu(entries: menu, help: "More for \(content.title)", onCommand: onMenu)
                    .focused($menuFocused)
                    .opacity(showsMenu ? 1 : 0)
            }
        }
        .kitRow(isSelected: isSelected)
        .onHover { isHovered = $0 }
        .contextMenu {
            let entries = menu.isEmpty ? contextEntries : menu
            if !entries.isEmpty { InboxMenuItems(entries: entries, onCommand: onMenu) }
        }
    }

    /// VoiceOver's one element: "title, preview, N" (the parts it has).
    static func accessibilityLabel(_ content: InboxRowContent) -> String {
        var parts = [content.title]
        if !content.preview.isEmpty { parts.append(content.preview) }
        if let pill = content.pill { parts.append("\(pill.count)") }
        return parts.joined(separator: ", ")
    }
}

/// A row's count: waits on the owner in the warning tone, news in the
/// accent, a batch to go through quiet on the card fill.
struct InboxRowPillView: View {
    let pill: InboxRowPill

    var body: some View {
        Text("\(pill.count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(pill.tone == .batch ? Color.secondary : Color.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Spacing.compact)
            .padding(.vertical, Spacing.tight)
            .background(Self.fill(pill.tone), in: Capsule())
            .accessibilityIdentifier("inbox.row.pill")
    }

    static func fill(_ tone: InboxRowPill.Tone) -> Color {
        switch tone {
        case .needsYou: Tone.warning
        case .news: Color.accentColor
        case .batch: Fill.card
        }
    }
}
