import SwiftUI

/// One coloured item of a meta line; the role says what it is, so
/// `OrangeToneTests` can sweep it.
struct MetaItem: Equatable {
    let text: String
    let tone: PhoneTone
    let role: ToneRole
}

/// Meta items spaced 6 and joined by "·" in secondary, on one line. Whole
/// items only: the longest prefix that fits, so the trailing items drop
/// first and a squeezed line never shows a one-letter stub; a shortened line
/// ends in "…", and VoiceOver hears every item. The first item alone
/// truncates when even it does not fit.
struct MetaLine: View {
    let items: [MetaItem]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.prefixLengths(items.count), id: \.self) { count in
                line(items.prefix(count), shortened: Self.isShortened(shown: count, of: items.count))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(items))
    }

    /// Every item, for VoiceOver, whatever fits on screen.
    static func spokenLabel(_ items: [MetaItem]) -> String {
        items.map(\.text).joined(separator: ", ")
    }

    static func isShortened(shown: Int, of count: Int) -> Bool {
        shown < count
    }

    /// The prefix lengths to try, longest first.
    static func prefixLengths(_ count: Int) -> [Int] {
        Array(stride(from: count, to: 0, by: -1))
    }

    private func line(_ shown: ArraySlice<MetaItem>, shortened: Bool) -> some View {
        HStack(spacing: Spacing.compact) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("·").foregroundStyle(.secondary)
                }
                Text(item.text).foregroundStyle(item.tone.color)
            }
            if shortened {
                Text("…").foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

/// A flat row's icon: an SF Symbol in a tone, a session dot, or nothing.
enum FlatRowIcon: Equatable {
    case symbol(String, tone: PhoneTone)
    case session(tone: PhoneTone, isRing: Bool)
}

/// The Mac's target row (`TargetsListView.swift:395-430`) at phone size
/// (design pass spec §2.7): a 20 pt icon column, the title (up to two
/// lines; struck through and secondary when dimmed), one meta line in
/// `.caption` secondary, and a trailing view. In a `ScrollView` it pads
/// itself with `RowInsets.flat`; in a `List` pass `insets: EdgeInsets()` and
/// let the list's row insets pad it.
struct FlatRow<Meta: View, Trailing: View>: View {
    let icon: FlatRowIcon
    let title: String
    var titleLineLimit = 2
    var isDimmed = false
    var insets = RowInsets.flat
    @ViewBuilder var meta: Meta
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            iconView.frame(width: 20)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title)
                    .font(TypeScale.rowTitle)
                    .strikethrough(isDimmed)
                    .foregroundStyle(isDimmed ? Color.secondary : Color.primary)
                    .lineLimit(titleLineLimit)
                meta
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(insets)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case let .symbol(name, tone):
            Image(systemName: name).font(.body).foregroundStyle(tone.color)
        case let .session(tone, isRing):
            SessionDot(tone: tone, isRing: isRing, size: 10)
        }
    }
}

extension FlatRow where Trailing == EmptyView {
    init(
        icon: FlatRowIcon,
        title: String,
        titleLineLimit: Int = 2,
        isDimmed: Bool = false,
        insets: EdgeInsets = RowInsets.flat,
        @ViewBuilder meta: () -> Meta
    ) {
        self.init(icon: icon, title: title, titleLineLimit: titleLineLimit, isDimmed: isDimmed, insets: insets, meta: meta) {
            EmptyView()
        }
    }
}

/// A divider between flat rows in a `ScrollView` or a card, starting at the
/// title column (16 + 20 + 10).
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 46)
    }
}

/// A section label in a `ScrollView`: `TypeScale.sectionHeader`, never
/// uppercase. In an `insetGrouped` or `plain` `List`, keep the system header
/// and give it `.font(TypeScale.sectionHeader)` and `.textCase(nil)`.
struct SectionHeader: View {
    let text: String
    let tone: PhoneTone

    init(_ text: String, tone: PhoneTone = .secondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(TypeScale.sectionHeader)
            .foregroundStyle(tone.color)
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 6, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
