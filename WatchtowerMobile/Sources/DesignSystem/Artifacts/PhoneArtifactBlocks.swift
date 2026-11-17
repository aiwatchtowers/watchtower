import SwiftUI
import WatchtowerDesign

// One view per block kind of `PhoneArtifactView` (mockup §4). Rows are flat
// and padded with `RowInsets.flat`; metrics and tables sit on cards inset
// like `RowInsets.card`.

struct PhoneArtifactHeading: View {
    let text: String
    let level: Int

    var body: some View {
        Text(text)
            .font(level == 1 ? Font.headline : TypeScale.rowEmphasis)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, RowInsets.flat.leading)
            .padding(.top, level == 1 ? Spacing.regular : Spacing.small)
    }
}

/// A `text` block: inline markdown (bold, italic, code, links), line
/// breaks kept, as the chat bubbles read it.
struct PhoneArtifactText: View {
    let markdown: String

    var body: some View {
        Text(Self.attributed(markdown))
            .font(TypeScale.rowTitle)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, RowInsets.flat.leading)
    }

    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

/// A `metrics` block: 2- or 3-up figures, each on its own card.
struct PhoneArtifactMetrics: View {
    let metrics: [ArtifactMetric]
    let columns: Int

    var body: some View {
        Grid(horizontalSpacing: Spacing.regular, verticalSpacing: Spacing.regular) {
            ForEach(Array(stride(from: 0, to: metrics.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + columns, metrics.count), id: \.self) { index in
                        figure(metrics[index])
                    }
                }
            }
        }
        // Each line of figures is as tall as its tallest, no taller.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, RowInsets.card.leading)
        .padding(.vertical, RowInsets.card.top)
    }

    private func figure(_ metric: ArtifactMetric) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(metric.value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(metric.tone.map { PhoneTone.artifact($0).color } ?? .primary)
            Text(metric.label).font(TypeScale.meta).foregroundStyle(.secondary)
            if let hint = metric.hint {
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card(padding: EdgeInsets(top: Spacing.regular, leading: Spacing.cozy, bottom: Spacing.regular, trailing: Spacing.cozy))
    }
}

/// A `list` block: flat rows, its title above, its empty line when it has
/// no rows.
struct PhoneArtifactListView: View {
    let list: PhoneArtifactList
    let onRef: (ArtifactRef) -> Void
    let onAction: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = list.title {
                PhoneArtifactBlockTitle(text: title)
            }
            if list.rows.isEmpty {
                Text(list.empty)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(RowInsets.flat)
            }
            ForEach(Array(list.rows.enumerated()), id: \.offset) { _, row in
                PhoneArtifactRowView(row: row, onRef: onRef, onAction: onAction)
            }
        }
    }
}

/// A list's or a table's own title.
struct PhoneArtifactBlockTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TypeScale.sectionHeader)
            .foregroundStyle(.secondary)
            .padding(.horizontal, RowInsets.flat.leading)
            .padding(.top, Spacing.regular)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A list row: its tone dot, the title (two lines), the subtitle, the badge
/// as a tone pill, then its buttons under the text.
struct PhoneArtifactRowView: View {
    let row: PhoneArtifactRow
    let onRef: (ArtifactRef) -> Void
    let onAction: (Int) -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.phoneArtifactInputs) private var inputs

    var body: some View {
        if case let .ref(ref) = row.press {
            let actions = inputs.refRow(ref)
            if !actions.hidden {
                refRow(ref, actions)
            }
        } else {
            plain
        }
    }

    private var plain: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            switch row.press {
            case let .link(url):
                Button { openURL(url) } label: { line(chevron: false, trailingText: nil) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isLink)
            case .ref, .none:
                line(chevron: false, trailingText: nil)
            }
            rowButtons
        }
        .padding(RowInsets.flat)
        .frame(minHeight: PhoneMetrics.minTouch)
    }

    /// A ref row: its swipes and context menu from the host, dimmed with a spinner while a press runs, its
    /// refusal and Retry under it.
    @ViewBuilder
    private func refRow(_ ref: ArtifactRef, _ actions: PhoneRefRowActions) -> some View {
        if actions.inline.isEmpty {
            refRowBody(ref, actions)
        } else {
            refRowBody(ref, actions)
                .card(.waiting, padding: EdgeInsets(top: Spacing.compact, leading: 0, bottom: Spacing.cozy, trailing: 0))
                .padding(.horizontal, Spacing.small)
        }
    }

    private func refRowBody(_ ref: ArtifactRef, _ actions: PhoneRefRowActions) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            SwipeRow(leading: actions.leading, trailing: actions.trailing, revealed: actions.revealed) {
                Button { onRef(ref) } label: {
                    line(chevron: actions.busyLabel == nil, trailingText: actions.trailingText, busy: actions.busyLabel != nil)
                        .padding(RowInsets.flat)
                        .frame(minHeight: PhoneMetrics.minTouch)
                }
                .buttonStyle(.plain)
                .contextMenu { PhoneMenuItems(entries: actions.menu) }
                .opacity(actions.busyLabel == nil ? 1 : PhoneOpacity.busy)
            }
            if let busy = actions.busyLabel {
                Text(busy).font(TypeScale.meta).foregroundStyle(.secondary).padding(.leading, Self.textInset)
            }
            if let error = actions.error {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(error).font(TypeScale.meta).foregroundStyle(PhoneTone.red.color)
                    if let retry = actions.retry {
                        Button(retry.title, action: retry.action).buttonStyle(PhoneArtifactButtonStyle(primary: false))
                    }
                }
                .padding(.leading, Self.textInset)
                .padding(.trailing, RowInsets.flat.trailing)
            }
            rowButtons.padding(.horizontal, RowInsets.flat.leading)
            if !actions.inline.isEmpty {
                FlowRow(spacing: Spacing.regular, lineSpacing: Spacing.regular) {
                    ForEach(Array(actions.inline.enumerated()), id: \.offset) { offset, entry in
                        Button(entry.title, action: entry.action)
                            .buttonStyle(PhoneArtifactButtonStyle(primary: offset == 0))
                            .disabled(!entry.enabled || actions.busyLabel != nil)
                    }
                }
                .padding(.leading, Self.textInset)
                .padding(.trailing, RowInsets.flat.trailing)
            }
        }
    }

    /// The row text's leading edge: the inset and the icon column.
    static var textInset: CGFloat { RowInsets.flat.leading + PhoneMetrics.iconColumn + Spacing.cozy }

    @ViewBuilder private var rowButtons: some View {
        if !row.buttons.isEmpty {
            PhoneArtifactButtons(buttons: row.buttons, onAction: onAction)
                .padding(.leading, PhoneMetrics.iconColumn + Spacing.cozy)
        }
    }

    private func line(chevron: Bool, trailingText: String?, busy: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
            Group {
                if let tone = row.tone {
                    Circle()
                        .fill(PhoneTone.artifact(tone).color)
                        .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                } else {
                    Color.clear.frame(width: IconSize.stateDot, height: IconSize.stateDot)
                }
            }
            .frame(width: PhoneMetrics.iconColumn)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(row.title)
                    .font(TypeScale.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Spacing.regular)
            if let badge = row.badge {
                Pill(text: badge.text, tone: PhoneTone.artifact(badge.tone))
            }
            if let trailingText {
                Text(trailingText).font(TypeScale.time).foregroundStyle(.secondary)
            }
            if busy {
                ProgressView().controlSize(.small)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A `table` block on a card: a header row in secondary, toned cells as
/// tone pills, linked cells in the accent colour. A table wider than a
/// phone scrolls sideways inside its card.
struct PhoneArtifactTable: View {
    let table: ArtifactBlock.Table
    let scrolls: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = table.title {
                PhoneArtifactBlockTitle(text: title).padding(.bottom, Spacing.small)
            }
            Group {
                if scrolls {
                    ScrollView(.horizontal) { grid }
                } else {
                    // The layout's estimate let it through; content that is
                    // still wider than the card scrolls rather than truncates.
                    ViewThatFits(in: .horizontal) {
                        grid
                        ScrollView(.horizontal) { grid }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .card(padding: EdgeInsets(top: Spacing.compact, leading: Spacing.cozy, bottom: Spacing.compact, trailing: Spacing.cozy))
            .padding(.horizontal, RowInsets.card.leading)
            .padding(.vertical, RowInsets.card.top)
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: Spacing.medium, verticalSpacing: Spacing.compact) {
            GridRow {
                ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                    Text(column.title)
                        .font(TypeScale.meta.weight(.medium))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(column.align == .trailing ? .trailing : .leading)
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                GridRow {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                        PhoneArtifactCell(cell: cell)
                    }
                }
            }
        }
        .lineLimit(1)
    }
}

struct PhoneArtifactCell: View {
    let cell: ArtifactTableCell
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let tone = cell.tone, !cell.text.isEmpty {
            Pill(text: cell.text, tone: PhoneTone.artifact(tone))
        } else if let url = PhoneArtifactLayout.webURL(cell.link) {
            Button(cell.text) { openURL(url) }
                .buttonStyle(.plain)
                .font(TypeScale.meta.monospacedDigit())
                .foregroundStyle(PhoneTone.accent.color)
                .accessibilityAddTraits(.isLink)
        } else {
            Text(cell.text).font(TypeScale.meta.monospacedDigit())
        }
    }
}

/// A `person` block as a flat row: initials in a circle, the name, the
/// role, then each line (in its tone when it has one).
struct PhoneArtifactPerson: View {
    let person: ArtifactBlock.Person
    let initials: String
    let link: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let link {
            Button { openURL(link) } label: { row }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            Text(initials)
                .font(TypeScale.badge)
                .foregroundStyle(.secondary)
                .frame(width: IconSize.tile, height: IconSize.tile)
                .background(Fill.card, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(person.name).font(TypeScale.rowTitle)
                if let role = person.role {
                    Text(role).font(TypeScale.meta).foregroundStyle(.secondary)
                }
                ForEach(Array(person.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(TypeScale.meta)
                        .foregroundStyle(line.tone.map { PhoneTone.artifact($0).color } ?? .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(RowInsets.flat)
        .contentShape(Rectangle())
    }
}

/// A `link` block as a flat row in the accent colour; a link the phone
/// does not open (`PhoneArtifactLayout.webURL`) draws as plain text.
struct PhoneArtifactLink: View {
    let title: String
    let subtitle: String
    let url: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url {
            Button { openURL(url) } label: { row(tone: .accent) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
        } else {
            row(tone: .secondary)
        }
    }

    private func row(tone: PhoneTone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
            Image(systemName: "link")
                .foregroundStyle(tone.color)
                .frame(width: PhoneMetrics.iconColumn)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title).font(TypeScale.rowTitle).foregroundStyle(tone.color)
                Text(subtitle)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if url != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(RowInsets.flat)
        .frame(minHeight: PhoneMetrics.minTouch)
        .contentShape(Rectangle())
    }
}

/// A row of buttons that wraps (mockup `.btns`): the primary one in the
/// accent fill, the rest on the card fill in the accent colour.
struct PhoneArtifactButtons: View {
    let buttons: [PhoneArtifactButton]
    let onAction: (Int) -> Void
    @Environment(\.phoneArtifactInputs) private var inputs

    var body: some View {
        let states = buttons.map { inputs.buttonState($0.index) }
        VStack(alignment: .leading, spacing: Spacing.compact) {
            FlowRow(spacing: Spacing.regular, lineSpacing: Spacing.regular) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { offset, button in
                    let state = states[offset]
                    Button { onAction(button.index) } label: {
                        if let busy = state.busyLabel {
                            HStack(spacing: Spacing.compact) {
                                ProgressView().controlSize(.mini)
                                Text(busy)
                            }
                        } else {
                            Text(state.label ?? button.label)
                        }
                    }
                    .buttonStyle(PhoneArtifactButtonStyle(primary: button.primary && state.enabled))
                    .disabled(!state.enabled || state.busyLabel != nil)
                    .opacity(state.enabled ? 1 : PhoneOpacity.disabled)
                }
            }
            ForEach(Array(states.compactMap(\.note).enumerated()), id: \.offset) { _, note in
                Text(note).font(TypeScale.meta).foregroundStyle(.secondary)
            }
        }
    }
}

struct PhoneArtifactButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(primary ? Color.white : PhoneTone.accent.color)
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.compact)
            .background(primary ? AnyShapeStyle(PhoneTone.accent.color) : AnyShapeStyle(Fill.card), in: shape)
            .opacity(configuration.isPressed ? PhoneOpacity.pressed : 1)
            .contentShape(shape)
    }
}
