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

/// A flat row's icon: an SF Symbol in a tone, a session dot, or a state
/// mark (a white glyph on a disc in the tone, mockups 1–2).
enum FlatRowIcon: Equatable {
    case symbol(String, tone: PhoneTone)
    case session(tone: PhoneTone, isRing: Bool)
    case state(glyph: String, tone: PhoneTone)
}

/// A row's plate, the Desktop's `.kitRow` on the phone: clear at rest,
/// `Fill.selected` when selected. Rows are separated by space, never by
/// dividers.
enum RowPlate {
    static func fill(isSelected: Bool) -> Color {
        isSelected ? Fill.selected : .clear
    }
}

/// The Mac's target row (`TargetsListView.swift:395-430`) at phone size
/// (design pass spec §2.7): a 20 pt icon column, the title (up to two
/// lines; struck through and secondary when dimmed), one meta line in
/// `.caption` secondary, and a trailing view, on a `RowPlate` (selected:
/// `Fill.selected`). In a `ScrollView` it pads itself with `RowInsets.flat`;
/// in a `List` pass `insets: EdgeInsets()` and let the list's row insets pad
/// it.
struct FlatRow<Meta: View, Trailing: View>: View {
    let icon: FlatRowIcon
    let title: String
    var titleLineLimit = 2
    var isDimmed = false
    var isSelected = false
    var insets = RowInsets.flat
    @ViewBuilder var meta: Meta
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
            iconView.frame(width: PhoneMetrics.iconColumn)
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
            Spacer(minLength: Spacing.regular)
            trailing
        }
        .padding(insets)
        .frame(minHeight: PhoneMetrics.minTouch)
        .background(RowPlate.fill(isSelected: isSelected), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case let .symbol(name, tone):
            Image(systemName: name).font(.body).foregroundStyle(tone.color)
        case let .session(tone, isRing):
            SessionDot(tone: tone, isRing: isRing)
        case let .state(glyph, tone):
            StateMark(glyph: glyph, tone: tone)
        }
    }
}

extension FlatRow where Trailing == EmptyView {
    init(
        icon: FlatRowIcon,
        title: String,
        titleLineLimit: Int = 2,
        isDimmed: Bool = false,
        isSelected: Bool = false,
        insets: EdgeInsets = RowInsets.flat,
        @ViewBuilder meta: () -> Meta
    ) {
        self.init(
            icon: icon, title: title, titleLineLimit: titleLineLimit, isDimmed: isDimmed, isSelected: isSelected,
            insets: insets, meta: meta
        ) {
            EmptyView()
        }
    }
}

/// The hairline between rows grouped on one card (mockups 1, 2, 9, 16):
/// `Stroke.hairline` in the separator colour, inset `inset` on both sides
/// (the rows' own side padding when they pad themselves). Only inside a
/// card: rows outside one are separated by space alone.
///
///     VStack(spacing: 0) { rowA; CardRowDivider(); rowB }.card()
struct CardRowDivider: View {
    static let lineWidth = Stroke.hairline
    static let color = Stroke.hairlineColor

    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Self.color)
            .frame(height: Self.lineWidth)
            .padding(.horizontal, inset)
            .accessibilityHidden(true)
    }
}

/// A section header of a scroll view (mockups' `.sec`, the Desktop Home's
/// zone titles): the title in caps with `Tracking.caps`, in the tone, and an
/// optional count trailing in secondary. It pads itself 20 on the sides (the
/// mockups' 16 content inset plus 4), 16 above and 8 below. In a system
/// `List`, keep the system header with `TypeScale.sectionHeader` and
/// `.textCase(nil)`.
///
///     SectionHeader("Waiting for you", count: 3, tone: .waitingForYou)
struct SectionHeader: View {
    let text: String
    let count: Int?
    let tone: PhoneTone

    init(_ text: String, count: Int? = nil, tone: PhoneTone = .secondary) {
        self.text = text
        self.count = count
        self.tone = tone
    }

    /// What VoiceOver reads: the title, then the count.
    static func spokenLabel(_ text: String, count: Int?) -> String {
        count.map { "\(text), \($0)" } ?? text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .textCase(.uppercase)
                .tracking(Tracking.caps)
                .foregroundStyle(tone.color)
            Spacer(minLength: Spacing.regular)
            if let count {
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(TypeScale.capsHeader)
        .padding(EdgeInsets(top: Spacing.large, leading: Spacing.page, bottom: Spacing.regular, trailing: Spacing.page))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(text, count: count))
        .accessibilityAddTraits(.isHeader)
    }
}
