import SwiftUI
import WatchtowerCore

/// What the Inbox header's ⋯ menu opens in the reading pane (R7): the two
/// editors the old Learned / Profile segments held.
enum InboxAuxPane: Equatable {
    case learnedRules, profile

    var title: String {
        switch self {
        case .learnedRules: "Learned Rules"
        case .profile: "Assistant Profile"
        }
    }
}

/// The Inbox header (spec C1 §6.1): the six filter segments (R8), the Ideas
/// filter's own controls (`ideasHeader`, empty until Task 10 fills it), the
/// reaction cheat sheet one `?` away, and the ⋯ menu with Learned Rules and
/// Assistant Profile.
struct InboxFilterBar<IdeasHeader: View>: View {
    @Binding var filter: InboxFilter
    let cheatSheetRows: [ReactionCheatSheet.Row]
    /// False while the empty All list shows the cheat sheet inline.
    let showsCheatSheetButton: Bool
    let onOpenSettings: () -> Void
    let onOpenAux: (InboxAuxPane) -> Void
    let ideasHeader: IdeasHeader

    @State private var showsCheatSheet = false

    init(
        filter: Binding<InboxFilter>,
        cheatSheetRows: [ReactionCheatSheet.Row],
        showsCheatSheetButton: Bool,
        onOpenSettings: @escaping () -> Void,
        onOpenAux: @escaping (InboxAuxPane) -> Void,
        @ViewBuilder ideasHeader: () -> IdeasHeader
    ) {
        _filter = filter
        self.cheatSheetRows = cheatSheetRows
        self.showsCheatSheetButton = showsCheatSheetButton
        self.onOpenSettings = onOpenSettings
        self.onOpenAux = onOpenAux
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
            showsCheatSheet = true
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.kitIcon(isOn: false))
        .help("Reaction commands")
        .accessibilityLabel("Reaction commands")
        .accessibilityIdentifier("actionStrip.cheatSheetButton")
        .popover(isPresented: $showsCheatSheet, arrowEdge: .bottom) {
            ReactionCheatSheetView(rows: cheatSheetRows, onOpenSettings: onOpenSettings)
                .frame(width: 440)
                .popoverSurface()
        }
    }

    private var moreMenu: some View {
        Menu {
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
    init(
        filter: Binding<InboxFilter>,
        cheatSheetRows: [ReactionCheatSheet.Row],
        showsCheatSheetButton: Bool,
        onOpenSettings: @escaping () -> Void,
        onOpenAux: @escaping (InboxAuxPane) -> Void
    ) {
        self.init(filter: filter, cheatSheetRows: cheatSheetRows, showsCheatSheetButton: showsCheatSheetButton,
                  onOpenSettings: onOpenSettings, onOpenAux: onOpenAux) { EmptyView() }
    }
}
