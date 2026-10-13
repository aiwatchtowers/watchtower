import SwiftUI

/// Settings → Macs (multi-hub spec §5.6): the linked Macs in order, reordered
/// with Edit, each Unlinked (a linked Mac) or Forgotten (one the Mac
/// removed, or long offline) from its swipe action or context menu; Add Mac
/// at the bottom as in the switcher.
struct MacsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    /// The Mac the owner is asked about, and what is asked.
    @State private var asking: Ask?

    struct Ask: Identifiable, Equatable {
        enum Kind { case unlink, forget }
        let kind: Kind
        let hubID: String
        let name: String
        var id: String { "\(kind)-\(hubID)" }

        var title: String {
            switch kind {
            case .unlink: "Unlink \(name)?"
            case .forget: "Forget \(name)?"
            }
        }

        var message: String {
            switch kind {
            case .unlink: "This phone forgets the Mac's data. Changes still waiting for the Mac are not sent."
            case .forget: "Its data on this iPhone is deleted."
            }
        }
    }

    var body: some View {
        // Online turns offline by the clock alone.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            list(HubListModel.items(rows: linking.links, sessions: env.sessions, activeHubID: env.activeHubID, now: context.date))
        }
        .navigationTitle("Macs")
        .toolbar {
            if linking.links.count > 1 {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        .confirmationDialog(
            asking?.title ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
            titleVisibility: .visible, presenting: asking
        ) { ask in
            Button(ask.kind == .unlink ? "Unlink" : "Forget", role: .destructive) {
                Task {
                    switch ask.kind {
                    case .unlink: await linking.unlink(ask.hubID)
                    case .forget: await linking.forget(ask.hubID)
                    }
                }
            }
        } message: { ask in
            Text(ask.message)
        }
    }

    private func list(_ items: [HubListItem]) -> some View {
        let canAdd = HubListModel.canAddMac(rows: linking.links)
        return List {
            Section {
                ForEach(items) { item in
                    HubListRow(item: item)
                        .listRowInsets(RowInsets.flat)
                        .swipeActions(edge: .trailing) { actions(item) }
                        .contextMenu { actions(item) }
                }
                .onMove { source, destination in
                    move(items, from: source, to: destination)
                }
            }
            Section {
                Button {
                    linking.startScan()
                } label: {
                    Label("Add Mac", systemImage: "qrcode.viewfinder")
                }
                .frame(minHeight: 44)
                .disabled(!canAdd || linking.isBusy)
            } footer: {
                if !canAdd {
                    Text("You can link up to \(HubRegistry.limit) Macs").font(TypeScale.meta)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Unlink for a linked Mac; Forget for one the Mac removed or long
    /// offline.
    @ViewBuilder private func actions(_ item: HubListItem) -> some View {
        if !item.removedByMac {
            Button("Unlink", role: .destructive) {
                asking = Ask(kind: .unlink, hubID: item.id, name: item.name)
            }
            .disabled(linking.isBusy)
        }
        if item.canForget {
            Button("Forget", role: .destructive) {
                asking = Ask(kind: .forget, hubID: item.id, name: item.name)
            }
            .disabled(linking.isBusy)
        }
    }

    /// `List.onMove`'s offsets become the registry's index of the moved Mac.
    private func move(_ items: [HubListItem], from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let to = destination > from ? destination - 1 : destination
        guard to != from else { return }
        linking.moveHub(items[from].id, to: to)
    }
}
