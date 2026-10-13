import SwiftUI

/// The list of linked Macs the switcher chip opens (multi-hub spec §5.6):
/// each Mac's name, flavor, online dot (or "Removed this phone"), days
/// offline, fetch problem and open asks, in registry order; then Add Mac,
/// off at the limit. Forgetting a Mac is in Settings → Macs.
struct HubListSheet: View {
    enum Choice: Equatable {
        case activate(String)
        case addMac
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    @Environment(\.dismiss) private var dismiss
    /// Called with the owner's choice; the caller dismisses the sheet and
    /// runs it once the sheet is gone.
    let choose: (Choice) -> Void

    var body: some View {
        NavigationStack {
            // Online turns offline by the clock alone.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                list(HubListModel.items(rows: linking.links, sessions: env.sessions, activeHubID: env.activeHubID, now: context.date))
            }
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func list(_ items: [HubListItem]) -> some View {
        let canAdd = HubListModel.canAddMac(rows: linking.links)
        return List {
            Section {
                ForEach(items) { item in
                    Button {
                        choose(.activate(item.id))
                    } label: {
                        HubListRow(item: item)
                    }
                    .listRowInsets(RowInsets.flat)
                    .accessibilityAddTraits(item.isActive ? .isSelected : [])
                }
            }
            Section {
                Button {
                    choose(.addMac)
                } label: {
                    Label("Add Mac", systemImage: "qrcode.viewfinder")
                }
                .frame(minHeight: 44)
                .disabled(!canAdd)
            } footer: {
                if !canAdd {
                    Text("You can link up to \(HubRegistry.limit) Macs").font(TypeScale.meta)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// One Mac in the list: the name, then the dot and state with the flavor,
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
                        Circle().fill(item.dotTone.color).frame(width: 8, height: 8)
                    }
                    Text(item.statusText)
                    if let flavor = item.flavor {
                        Text("·")
                        Text(flavor)
                    }
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
