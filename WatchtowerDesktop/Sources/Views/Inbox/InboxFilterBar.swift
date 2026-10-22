import SwiftUI
import WatchtowerCore

/// What the Inbox header opens in the reading pane: the reaction cheat sheet
/// (`?`), and from the ⋯ menu the two editors the old Learned / Profile
/// segments held (R7). Nothing in the Inbox header is a pop-up.
enum InboxAuxPane: Equatable {
    case reactionCommands, learnedRules, profile

    var title: String {
        switch self {
        case .reactionCommands: "Reaction Commands"
        case .learnedRules: "Learned Rules"
        case .profile: "Assistant Profile"
        }
    }
}

/// The Inbox header (spec C1 §6.1): the six filter segments (R8), the Ideas
/// filter's own controls (`ideasHeader`: `InboxIdeasHeader`'s `+`), the
/// reaction cheat sheet one `?` away and the ⋯ menu with Learned Rules and
/// Assistant Profile — each opens in the reading pane — and, on the Ideas
/// filter, **Find Ideas in Past Messages…** (`onFindIdeas`, an inline row).
struct InboxFilterBar<IdeasHeader: View>: View {
    @Binding var filter: InboxFilter
    /// False while the empty All list shows the cheat sheet inline.
    let showsCheatSheetButton: Bool
    let onOpenAux: (InboxAuxPane) -> Void
    /// The Ideas filter's ⋯ item; nil leaves it out.
    let onFindIdeas: (() -> Void)?
    let ideasHeader: IdeasHeader

    init(
        filter: Binding<InboxFilter>,
        showsCheatSheetButton: Bool,
        onOpenAux: @escaping (InboxAuxPane) -> Void,
        onFindIdeas: (() -> Void)? = nil,
        @ViewBuilder ideasHeader: () -> IdeasHeader
    ) {
        _filter = filter
        self.showsCheatSheetButton = showsCheatSheetButton
        self.onOpenAux = onOpenAux
        self.onFindIdeas = onFindIdeas
        self.ideasHeader = ideasHeader()
    }

    var body: some View {
        HStack(spacing: Spacing.regular) {
            KitSegmentedPicker(
                title: "Filter",
                selection: $filter,
                segments: InboxFilter.allCases.map { KitSegment(value: $0, title: $0.title) }
            )
            .fixedSize()
            if filter == .ideas {
                ideasHeader
            }
            Spacer(minLength: 0)
            if showsCheatSheetButton {
                cheatSheetButton
            }
            moreMenu
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
    }

    private var cheatSheetButton: some View {
        Button {
            onOpenAux(.reactionCommands)
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.kitIcon(isOn: false))
        .help("Reaction commands")
        .accessibilityLabel("Reaction commands")
        .accessibilityIdentifier("actionStrip.cheatSheetButton")
    }

    private var moreMenu: some View {
        Menu {
            if filter == .ideas, let onFindIdeas {
                Button("Find Ideas in Past Messages…", action: onFindIdeas)
            }
            ForEach([InboxAuxPane.learnedRules, .profile], id: \.title) { pane in
                Button(pane.title) { onOpenAux(pane) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.kitIcon(isOn: false))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

extension InboxFilterBar where IdeasHeader == EmptyView {
    init(filter: Binding<InboxFilter>, showsCheatSheetButton: Bool, onOpenAux: @escaping (InboxAuxPane) -> Void) {
        self.init(filter: filter, showsCheatSheetButton: showsCheatSheetButton, onOpenAux: onOpenAux) {
            EmptyView()
        }
    }
}

/// The inline row the Ideas filter opens under the header.
enum InboxIdeasRow: Equatable {
    case newIdea, findIdeas
}

/// The Ideas filter's header control: `+` opens the New idea row; while a
/// backfill mines, a Mining… mark opens its row again.
struct InboxIdeasHeader: View {
    let isMining: Bool
    @Binding var row: InboxIdeasRow?

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Button { row = .newIdea } label: { Image(systemName: "plus") }
                .buttonStyle(.kitIcon(isOn: row == .newIdea))
                .help("New Idea")
                .accessibilityLabel("New Idea")
            if isMining {
                Button { row = .findIdeas } label: {
                    HStack(spacing: Spacing.small) {
                        ProgressView().controlSize(.small)
                        Text("Mining…").font(.caption)
                    }
                }
                .buttonStyle(.kitQuiet)
                .help("Finding ideas in past messages")
            }
        }
    }
}
