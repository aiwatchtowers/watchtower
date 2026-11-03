import SwiftUI

/// An Inbox card's blocks, top to bottom at the width its host gives it
/// (the host keeps one readable column), then the card's own buttons.
/// Kit parts only: no separators, colours only through `Tone.artifact`.
/// What the app owns (markdown, avatars, presses, ref hooks, target
/// states) comes from `\.artifactEnvironment`.
public struct ArtifactView: View {
    let document: ArtifactDocument
    let cardActions: [ArtifactAction]
    let mode: ArtifactRenderMode

    public init(document: ArtifactDocument, cardActions: [ArtifactAction] = [], mode: ArtifactRenderMode) {
        self.document = document
        self.cardActions = cardActions
        self.mode = mode
    }

    public var body: some View {
        let offsets = document.blockActionOffsets(cardActionCount: cardActions.count)
        VStack(alignment: .leading, spacing: Spacing.medium) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                ArtifactBlockView(block: block, firstIndex: offsets[index], mode: mode)
            }
            if !cardActions.isEmpty {
                ArtifactActionsView(actions: cardActions, firstIndex: 0, mode: mode, cardLevel: true)
                    .padding(.top, Spacing.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card's body by what its `blocks_json` decodes to (spec "Today's
/// Inbox"): the blocks; the markdown body as one text block when there are
/// none; the plain-text body with one line saying why for a newer version
/// or a layout that can't be read. The card's own buttons follow.
public struct ArtifactCardBody: View {
    let result: ArtifactDecodeResult
    /// The stored `body`: the markdown of a card without blocks, else Go's plain text.
    let text: String
    let cardActions: [ArtifactAction]
    let mode: ArtifactRenderMode

    public static let unsupportedLine = "This card needs a newer Watchtower"
    public static let unreadableLine = "This card's layout can't be read"

    public init(
        result: ArtifactDecodeResult,
        text: String,
        cardActions: [ArtifactAction] = [],
        mode: ArtifactRenderMode
    ) {
        self.result = result
        self.text = text
        self.cardActions = cardActions
        self.mode = mode
    }

    /// A stored card: its `blocks_json` and its own `actions_json`, decoded
    /// together (`ArtifactDocument.decodeCard`), so undecodable buttons draw
    /// the unreadable fallback instead of shifting every press index.
    public init(blocksJSON: String, actionsJSON: String, text: String, mode: ArtifactRenderMode) {
        let card = ArtifactDocument.decodeCard(blocksJSON: blocksJSON, actionsJSON: actionsJSON)
        self.init(result: card.result, text: text, cardActions: card.cardActions, mode: mode)
    }

    public var body: some View {
        switch result {
        case let .document(document):
            ArtifactView(document: document, cardActions: cardActions, mode: mode)
        case .none:
            ArtifactView(document: ArtifactDocument(blocks: text.isEmpty ? [] : [.text(markdown: text)]),
                         cardActions: cardActions, mode: mode)
        case .unsupported:
            fallback(Self.unsupportedLine)
        case .unreadable:
            fallback(Self.unreadableLine)
        }
    }

    private func fallback(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Label(line, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Tone.warning)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ArtifactView(document: ArtifactDocument(blocks: []), cardActions: cardActions, mode: mode)
        }
    }
}

struct ArtifactBlockView: View {
    let block: ArtifactBlock
    let firstIndex: Int
    let mode: ArtifactRenderMode

    var body: some View {
        switch block {
        case let .heading(text, level):
            ArtifactHeadingView(text: text, level: level)
        case let .text(markdown):
            ArtifactTextView(markdown: markdown)
        case let .list(list):
            ArtifactListView(list: list, firstIndex: firstIndex, mode: mode)
        case let .table(table):
            ArtifactTableView(table: table)
        case let .person(person):
            ArtifactPersonView(person: person)
        case let .metrics(items):
            ArtifactMetricsView(items: items)
        case let .link(title, url, subtitle):
            ArtifactLinkView(title: title, url: url, subtitle: subtitle)
        case let .actions(actions):
            ArtifactActionsView(actions: actions, firstIndex: firstIndex, mode: mode, cardLevel: false)
        }
    }
}

// MARK: - Blocks

struct ArtifactHeadingView: View {
    let text: String
    let level: Int

    var body: some View {
        Text(text)
            .font(level == 1 ? .headline : .subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ArtifactTextView: View {
    let markdown: String
    @Environment(\.artifactEnvironment) private var environment

    var body: some View {
        environment.markdown(markdown)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A block's own title (a list's, a table's): small and secondary.
struct ArtifactBlockTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct ArtifactListView: View {
    let list: ArtifactBlock.List
    let firstIndex: Int
    let mode: ArtifactRenderMode
    @Environment(\.artifactEnvironment) private var environment

    var body: some View {
        let offsets = list.rowActionOffsets(start: firstIndex)
        let shown = list.rows.indices.filter { index in
            list.rows[index].ref.map(environment.refHooks.isOpen) ?? true
        }
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let title = list.title { ArtifactBlockTitle(text: title).padding(.horizontal, Spacing.regular) }
            if shown.isEmpty {
                Text(list.empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.regular)
                    .padding(.vertical, Spacing.compact)
            }
            ForEach(shown, id: \.self) { index in
                ArtifactListRowView(row: list.rows[index], firstIndex: offsets[index], mode: mode)
            }
        }
        // The rows' hover plates sit flush with the card's other blocks.
        .padding(.horizontal, -Spacing.regular)
    }
}

struct ArtifactListRowView: View {
    let row: ArtifactListRow
    let firstIndex: Int
    let mode: ArtifactRenderMode
    @Environment(\.artifactEnvironment) private var environment

    var body: some View {
        let hidden = row.ref.map(environment.refHooks.nativeKinds) ?? []
        HStack(alignment: .center, spacing: Spacing.regular) {
            if let tone = row.tone {
                Circle()
                    .fill(Tone.artifact(tone))
                    .frame(width: IconSize.stateDot, height: IconSize.stateDot)
            }
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Text(row.title)
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge = row.badge {
                        Chip(text: badge.text, color: Tone.artifact(badge.tone))
                    }
                }
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.regular)
            ForEach(Array(row.actions.enumerated()), id: \.offset) { offset, action in
                if !hidden.contains(action.kind) {
                    ArtifactActionButton(action: action, index: firstIndex + offset, mode: mode, prominent: false)
                }
            }
            if let ref = row.ref, let native = environment.refHooks.nativeActions(ref, mode) {
                native
            }
        }
        .controlSize(.small)
        .kitRow(isSelected: false)
        .modifier(ArtifactLinkTap(link: row.link))
    }
}

struct ArtifactTableView: View {
    let table: ArtifactBlock.Table

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            if let title = table.title { ArtifactBlockTitle(text: title) }
            Grid(alignment: .leading, horizontalSpacing: Spacing.medium, verticalSpacing: Spacing.compact) {
                GridRow {
                    ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                        Text(column.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(column.align == .trailing ? .trailing : .leading)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                            ArtifactTableCellView(cell: cell)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.cozy)
            .card()
        }
    }
}

struct ArtifactTableCellView: View {
    let cell: ArtifactTableCell

    var body: some View {
        Text(cell.text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(cell.link != nil ? Color.accentColor : cell.tone.map(Tone.artifact) ?? .primary)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(ArtifactLinkTap(link: cell.link))
    }
}

struct ArtifactPersonView: View {
    let person: ArtifactBlock.Person
    @Environment(\.artifactEnvironment) private var environment

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            avatar
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Text(person.name).font(.callout.weight(.semibold))
                    if let role = person.role {
                        Text(role).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(person.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.caption)
                        .foregroundStyle(line.tone.map(Tone.artifact) ?? .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.cozy)
        .card()
        .modifier(ArtifactLinkTap(link: person.link))
    }

    @ViewBuilder private var avatar: some View {
        if let user = person.slackUser, let resolved = environment.avatar(user) {
            resolved
                .frame(width: IconSize.tile, height: IconSize.tile)
                .clipShape(Circle())
        } else {
            Text(Self.initials(person.name))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: IconSize.tile, height: IconSize.tile)
                .background(Fill.selected, in: Circle())
        }
    }

    /// "Colleague A" → "CA": the first letter of the first two words.
    static func initials(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct ArtifactMetricsView: View {
    let items: [ArtifactMetric]

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, metric in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(metric.label).font(.caption).foregroundStyle(.secondary)
                    Text(metric.value)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(metric.tone.map(Tone.artifact) ?? .primary)
                    if let hint = metric.hint {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Spacing.regular)
                .card()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ArtifactLinkView: View {
    let title: String
    let url: String
    let subtitle: String?

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.regular) {
            Image(systemName: "link")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
                Text(subtitle ?? url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .kitRow(isSelected: false)
        .padding(.horizontal, -Spacing.regular)
        .modifier(ArtifactLinkTap(link: url))
    }
}

/// A row of buttons: an `actions` block, or the card's own buttons
/// (`cardLevel`), where the first primary one is the prominent action.
struct ArtifactActionsView: View {
    let actions: [ArtifactAction]
    let firstIndex: Int
    let mode: ArtifactRenderMode
    let cardLevel: Bool

    var body: some View {
        let prominent = cardLevel ? actions.firstIndex(where: \.primary) : nil
        HStack(spacing: Spacing.regular) {
            ForEach(Array(actions.enumerated()), id: \.offset) { offset, action in
                ArtifactActionButton(action: action, index: firstIndex + offset, mode: mode,
                                     prominent: offset == prominent)
            }
        }
        .controlSize(.small)
    }
}

/// One button by its flattened index. In `.preview` every button is drawn
/// disabled with the reason as its help.
struct ArtifactActionButton: View {
    let action: ArtifactAction
    let index: Int
    let mode: ArtifactRenderMode
    let prominent: Bool
    @Environment(\.artifactEnvironment) private var environment

    var body: some View {
        if case .target = action.payload {
            ArtifactTargetButton(label: action.label, state: environment.targetButtonState(index), mode: mode) {
                environment.onAction(index)
            }
        } else if mode == .preview {
            plain.disabled(true).help(ArtifactRenderMode.previewButtonHelp)
        } else {
            plain
        }
    }

    @ViewBuilder private var plain: some View {
        let press = { environment.onAction(index) }
        if prominent && mode == .inbox {
            Button(action.label, action: press).buttonStyle(.kitPrimary)
        } else {
            Button(action: press) {
                if let symbol = Self.symbol(action.kind) {
                    Label(action.label, systemImage: symbol)
                } else {
                    Text(action.label)
                }
            }
            .buttonStyle(.kitSecondary)
        }
    }

    static func symbol(_ kind: ArtifactActionKind) -> String? {
        switch kind {
        case .chat: "bubble.left"
        case .agent: "sparkles"
        case .reply: "arrowshape.turn.up.left"
        // A target action draws `ArtifactTargetButton` instead.
        case .open, .target: nil
        }
    }
}

/// A whole row or card that opens its link, in the Inbox and the preview alike.
/// Known limitation: a tap gesture is not a focusable control, so these
/// links (list rows, table cells, the link block, a person card) cannot be
/// reached or opened from the keyboard; VoiceOver sees them as links.
struct ArtifactLinkTap: ViewModifier {
    let link: String?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        if let link, let url = URL(string: link) {
            content
                .contentShape(Rectangle())
                .onTapGesture { openURL(url) }
                .help(link)
                .accessibilityAddTraits(.isLink)
        } else {
            content
        }
    }
}
