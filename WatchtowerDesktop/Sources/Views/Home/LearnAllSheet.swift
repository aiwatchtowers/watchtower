import SwiftUI
import WatchtowerCore

/// Learn → See all (design §9.4): New in X.Y on top, then one section per
/// area with its own "n of m", filters for level and kind; seen cards stay
/// listed, dimmed, with Show again (or "In use" for a card whose feature
/// is in use).
struct LearnAllSheet: View {
    let selection: LearnSelection
    let actions: LearnZoneActions
    let onDone: () -> Void
    @State private var level: LearnLevel?
    @State private var kind: LearnKind?

    /// A section as the sheet lists it: the filtered rows under the
    /// section's unfiltered progress.
    struct Section: Equatable {
        let title: String
        let seenCount: Int
        let total: Int
        let rows: [LearnPick]
    }

    init(
        selection: LearnSelection,
        actions: LearnZoneActions,
        level: LearnLevel? = nil,
        kind: LearnKind? = nil,
        onDone: @escaping () -> Void
    ) {
        self.selection = selection
        self.actions = actions
        self.onDone = onDone
        _level = State(initialValue: level)
        _kind = State(initialValue: kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            filters
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.large) {
                    let sections = Self.sections(selection, level: level, kind: kind)
                    if sections.isEmpty {
                        Text("No cards match these filters.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sections, id: \.title) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, Spacing.page)
                .padding(.vertical, Spacing.medium)
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 620)
        .background(Surface.window)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text("Learn Watchtower")
                .font(.title3.weight(.semibold))
            Text("\(selection.seenCount) of \(selection.total) seen")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(.kitPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Spacing.page)
        .padding(.top, Spacing.large)
        .padding(.bottom, Spacing.medium)
    }

    private var filters: some View {
        HStack(spacing: Spacing.large) {
            KitSegmentedPicker(title: "Level", selection: $level, segments: [
                KitSegment(value: nil, title: "All levels"),
                KitSegment(value: .basics, title: "Basics"),
                KitSegment(value: .next, title: "Next"),
                KitSegment(value: .power, title: "Power")
            ])
            KitSegmentedPicker(title: "Kind", selection: $kind, segments: [
                KitSegment(value: nil, title: "All kinds"),
                KitSegment(value: .feature, title: "Features"),
                KitSegment(value: .tip, title: "Tips"),
                KitSegment(value: .shortcut, title: "Shortcuts")
            ])
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.page)
        .padding(.bottom, Spacing.regular)
    }

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                Text("\(section.seenCount) of \(section.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Spacing.regular)
            ForEach(section.rows) { pick in
                LearnAllRow(pick: pick, actions: actions)
            }
        }
    }

    /// The selection's sections with `level` and `kind` applied (nil = all);
    /// a section left without rows is left out.
    static func sections(_ selection: LearnSelection, level: LearnLevel?, kind: LearnKind?) -> [Section] {
        selection.sections.compactMap { section in
            let rows = section.cards.filter { pick in
                (level == nil || pick.card.level == level) && (kind == nil || pick.card.kind == kind)
            }
            guard !rows.isEmpty else { return nil }
            let title: String
            switch section.kind {
            case .new(let version): title = "New in \(version)"
            case .area(let area): title = LearnText.areaTitle(area)
            }
            return Section(title: title, seenCount: section.seenCount, total: section.total, rows: rows)
        }
    }
}

/// One See all row: icon, title and text, the level, then the card's button
/// or, once seen, Show again; an in-use card says so instead (Show again
/// would be undone by the next read).
struct LearnAllRow: View {
    let pick: LearnPick
    let actions: LearnZoneActions

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Image(systemName: LearnText.symbol(pick.card.area))
                .foregroundStyle(.tint)
                .frame(width: IconSize.composerLarge)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.compact) {
                    Text(LearnText.styled(pick.card.title))
                        .fontWeight(.semibold)
                    LearnBadge(variant: pick.variant)
                }
                Text(LearnText.styled(LearnText.text(pick)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .opacity(pick.seen ? 0.5 : 1)
            Spacer(minLength: Spacing.regular)
            Text(pick.card.level.rawValue)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if pick.canShowAgain {
                Button("Show again") { actions.showAgain(pick.id) }
                    .buttonStyle(.kitQuiet)
            } else if pick.seen {
                Text("In use")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(LearnText.primaryTitle(LearnPrimary(pick))) { actions.primary(pick) }
                    .buttonStyle(.kitSecondary)
            }
        }
        .controlSize(.small)
        .kitRow(isSelected: false)
    }
}
