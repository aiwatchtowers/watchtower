import SwiftUI

/// The list of linked hubs the switcher chip opens (multi-hub spec §5.6,
/// #1782): a note on what a pick does, then each hub's name, state, flavor,
/// questions waiting and problem lines in registry order, then Add Mac (off at
/// the limit; a live build only: `MacsView.offersAdd`). A tap on a row
/// switches and closes the list. Forgetting a hub is in Settings → Macs.
struct HubListSheet: View {
    enum Choice: Equatable {
        case activate(String)
        case addMac
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    /// Called with the owner's choice; the caller dismisses the sheet and
    /// runs it once the sheet is gone.
    let choose: (Choice) -> Void

    var body: some View {
        // Online turns asleep by the clock alone.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HubListSheetContent(
                rows: env.hubListItems(linking.links, unreadable: linking.unreadableHubIDs, now: context.date)
                    .map { HubSwitcherRowModel($0, now: context.date) },
                add: !MacsView.offersAdd(backend: env.backend) ? .hidden
                    : HubListModel.canAddMac(rows: linking.links, unreadable: linking.unreadableHubIDs) ? .on : .atLimit,
                choose: choose
            )
        }
    }
}

/// The list over its rows and its Add Mac row.
struct HubListSheetContent: View {
    enum AddRow {
        /// The demo: no linking.
        case hidden
        case on
        /// Off, with the limit's note.
        case atLimit
    }

    let rows: [HubSwitcherRowModel]
    let add: AddRow
    let choose: (HubListSheet.Choice) -> Void

    var body: some View {
        NavigationStack {
            List {
                Text(HubSwitcherText.sheetNote)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .macsListRow()
                ForEach(rows) { row in
                    Button {
                        choose(.activate(row.id))
                    } label: {
                        HubSwitcherRow(row: row)
                    }
                    .buttonStyle(.plain)
                    .macsListRow()
                    .disabled(!row.isEnabled)
                    .accessibilityAddTraits(row.isActive ? .isSelected : [])
                }
                if add != .hidden {
                    addRow(canAdd: add == .on)
                }
            }
            .macsList()
            .navigationTitle(HubSwitcherText.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func addRow(canAdd: Bool) -> some View {
        Button {
            choose(.addMac)
        } label: {
            FlatRow(
                icon: .symbol("qrcode.viewfinder", tone: canAdd ? .accent : .secondary),
                title: HubSwitcherText.addRow,
                insets: EdgeInsets()
            ) {
                if !canAdd {
                    Text(HubSwitcherText.limitNote(HubRegistry.limit))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .macsListRow()
    }
}

/// One hub in the list: the name, then the dot, state and flavor, then the
/// questions waiting (waiting tone) and the transport, term and problem
/// lines; the checkmark on the hub on screen.
struct HubSwitcherRow: View {
    let row: HubSwitcherRowModel

    var body: some View {
        FlatRow(
            icon: .symbol("laptopcomputer", tone: .secondary),
            title: row.name,
            titleLineLimit: 2,
            insets: EdgeInsets()
        ) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.compact) {
                    Circle().fill(row.dotTone.color).frame(width: PhoneMetrics.macDot, height: PhoneMetrics.macDot)
                    Text(row.status)
                    if let flavor = row.flavor {
                        Text("·")
                        Text(flavor)
                    }
                }
                if let waiting = row.waiting {
                    Text(waiting).foregroundStyle(PhoneTone.waitingForYou.color)
                }
                ForEach(row.lines, id: \.self) { line in
                    // The whole line: a term warning says why and when the link ends (S61).
                    Text(line)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } trailing: {
            if row.isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(PhoneTone.accent.color)
                    .accessibilityLabel(HubSwitcherText.currentLabel)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One Mac in Settings → Macs: the name, then the dot and state with the flavor,
/// then the last fetch's problem; the open asks and the active mark on the
/// right.
struct HubListRow: View {
    let item: HubListItem

    var body: some View {
        FlatRow(
            icon: .symbol("laptopcomputer", tone: .secondary),
            title: item.name,
            titleLineLimit: 1,
            insets: EdgeInsets()
        ) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.compact) {
                    if !item.removedByMac {
                        Circle().fill(item.dotTone.color).frame(width: PhoneMetrics.macDot, height: PhoneMetrics.macDot)
                    }
                    Text(item.statusText)
                    if let flavor = item.flavor {
                        Text("·")
                        Text(flavor)
                    }
                }
                if let transport = item.transportLine {
                    Text(transport)
                }
                if let term = item.termLine {
                    // The whole warning, not one line: it says why and when the link ends (S61).
                    Text(term)
                        .foregroundStyle(PhoneTone.secondary.color)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem = item.problem {
                    Text(problem)
                }
            }
        } trailing: {
            HStack(spacing: Spacing.regular) {
                if item.openAsks > 0 {
                    CountBadge(count: item.openAsks, tone: .waitingForYou)
                        .accessibilityLabel(item.openAsks == 1 ? "1 open ask" : "\(item.openAsks) open asks")
                }
                if item.isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(PhoneTone.accent.color)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
