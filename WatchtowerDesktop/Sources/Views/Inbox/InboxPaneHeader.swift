import SwiftUI
import WatchtowerCore

/// The top of a reading pane (spec "The reading pane", mockup `.phead`): the
/// entry's kind tile, its title and the line under it, the pane's actions on
/// the trailing end. The subtitle wraps; the actions never do.
struct InboxPaneHeader<Actions: View>: View {
    let tile: InboxTile
    let title: String
    let subtitle: String
    let actions: Actions
    /// The subtitle as a quiet link (`subtitleAction(help:_:)`); nil = text.
    private var onSubtitle: (() -> Void)?
    private var subtitleHelp = ""

    init(tile: InboxTile, title: String, subtitle: String, @ViewBuilder actions: () -> Actions) {
        self.tile = tile
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    /// This header with its subtitle drawn as a quiet button (an artifact's
    /// provenance line opens its run).
    func subtitleAction(help: String, _ action: (() -> Void)?) -> Self {
        var header = self
        header.onSubtitle = action
        header.subtitleHelp = help
        return header
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            tile
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !subtitle.isEmpty {
                    if let onSubtitle {
                        Button(action: onSubtitle) {
                            Text(subtitle)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.kitQuiet)
                        .help(subtitleHelp)
                        .accessibilityIdentifier("inbox.paneHeader.subtitle")
                    } else {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Spacing.small) {
                actions
            }
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// An automation artifact's pane header: its row's tile and title, the
/// card's provenance line, then the pane's own button (`leadingAction`,
/// Slack today's **Mark All Seen**), **Run Now** (only when its ⋯ offers
/// it), the ⋯ and the reaction commands' `?`.
struct InboxArtifactPaneHeader: View {
    /// The artifact's list row (`InboxFolderEntries.content`).
    let content: InboxRowContent
    /// `InboxCardTexts.readingSourceLine`.
    let subtitle: String
    /// A high-priority card keeps its chip.
    var isHighPriority = false
    /// Its ⋯; nil (tests, shots) draws neither the ⋯ nor Run Now.
    let menu: InboxArtifactMenuState?
    /// The provenance line's press: the run that wrote the card; nil = text.
    var onOpenRun: (() -> Void)?
    /// The `?`; nil draws none.
    let onReactionCommands: (() -> Void)?
    /// A pane's own button before Run Now (`leadingAction(_:)`); nil = none.
    private var leading: AnyView?

    private var offersRunNow: Bool {
        menu?.entries.contains { $0.command == .runNow } ?? false
    }

    /// This header with `button` before Run Now, the ⋯ and the `?`.
    func leadingAction(_ button: some View) -> Self {
        var header = self
        header.leading = AnyView(button)
        return header
    }

    var body: some View {
        InboxPaneHeader(tile: InboxTile(kind: content.kind, symbol: content.symbol), title: content.title,
                        subtitle: subtitle) {
            if isHighPriority {
                Chip(text: "High", color: Tone.priority("high"))
            }
            if let leading {
                leading
            }
            if let menu {
                if offersRunNow {
                    Button("Run Now") { menu.onCommand(.runNow) }
                        .buttonStyle(.kitSecondary)
                        .disabled(menu.isDisabled || menu.isWorking)
                        .accessibilityIdentifier("inbox.paneHeader.runNow")
                }
                InboxArtifactMenuButton(menu: menu)
            }
            if let onReactionCommands {
                InboxReactionCommandsButton(action: onReactionCommands)
            }
        }
        .subtitleAction(help: "Open the automation run", onOpenRun)
    }
}

/// The `?` that opens the reaction cheat sheet in the reading pane: on the
/// trailing end of every pane header and of Needs approval's.
struct InboxReactionCommandsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.kitIcon(isOn: false))
        .help("Reaction commands")
        .accessibilityLabel("Reaction commands")
        .accessibilityIdentifier("actionStrip.cheatSheetButton")
    }
}
