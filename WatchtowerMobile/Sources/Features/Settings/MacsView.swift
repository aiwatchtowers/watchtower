import SwiftUI

/// Settings → Macs (multi-hub spec §5.6): the linked Macs in order, reordered
/// with Edit, each Unlinked or Forgotten (`MacsModel.action`) from its swipe
/// action or context menu; Add Mac at the bottom as in the switcher.
struct MacsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    /// The Mac the owner is asked about, and what is asked.
    @State private var asking: MacsModel.Ask?

    var body: some View {
        // Online turns offline by the clock alone.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            list(env.hubListItems(linking.links, unreadable: linking.unreadableHubIDs, now: context.date))
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
            Button(ask.button, role: .destructive) {
                Task {
                    switch ask.action {
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
        let canAdd = HubListModel.canAddMac(rows: linking.links, unreadable: linking.unreadableHubIDs)
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
                .moveDisabled(linking.isBusy)
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

    /// The demo has no link to end: only a live build offers Unlink and
    /// Forget; reorder and Add Mac stay in both.
    static func offersRemoval(transportKind: TransportKind) -> Bool {
        transportKind != .inMemoryDemo
    }

    /// The row's one destructive action (`MacsModel.action`).
    @ViewBuilder private func actions(_ item: HubListItem) -> some View {
        if Self.offersRemoval(transportKind: env.transportKind) {
            let action = MacsModel.action(for: item)
            Button(action == .unlink ? "Unlink" : "Forget", role: .destructive) {
                asking = MacsModel.Ask(action: action, item: item)
            }
            .disabled(linking.isBusy)
        }
    }

    /// `List.onMove`'s offsets become the registry's index of the moved Mac
    /// (`MacsModel.registryMove`).
    private func move(_ items: [HubListItem], from source: IndexSet, to destination: Int) {
        guard let move = MacsModel.registryMove(items, from: source, to: destination) else { return }
        linking.moveHub(move.hubID, to: move.index)
    }
}

/// No hub on screen while the registry still holds Macs, none of which
/// opens (`AppRoot.showsUnopenedMacs`, #222): at launch, or after the last
/// Mac that opened went. Each is listed with its problem and **Forget**;
/// **Try Again** builds their sessions again (`AppRoot.reopenHubs`), and
/// **Add Mac** scans while a place is free. Forgetting the last one leaves
/// Welcome.
struct UnopenedMacsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    let retry: @MainActor () async -> Void
    @State private var asking: MacsModel.Ask?
    @State private var retrying = false

    var body: some View {
        let items = env.hubListItems(linking.links, unreadable: linking.unreadableHubIDs, now: .now)
        let canAdd = HubListModel.canAddMac(rows: linking.links, unreadable: linking.unreadableHubIDs)
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        HubListRow(item: item)
                            .listRowInsets(RowInsets.flat)
                            .swipeActions(edge: .trailing) { forget(item) }
                            .contextMenu { forget(item) }
                    }
                } header: {
                    Text("Watchtower couldn't open the data of these Macs on this iPhone. Try again, or forget a Mac and link it again.")
                        .textCase(nil)
                }
                Section {
                    Button {
                        retrying = true
                        Task {
                            await retry()
                            retrying = false
                        }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .frame(minHeight: 44)
                    .disabled(retrying || linking.isBusy)
                    Button {
                        linking.startScan()
                    } label: {
                        Label("Add Mac", systemImage: "qrcode.viewfinder")
                    }
                    .frame(minHeight: 44)
                    .disabled(!canAdd || linking.isBusy)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Macs")
        }
        .confirmationDialog(
            asking?.title ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
            titleVisibility: .visible, presenting: asking
        ) { ask in
            Button(ask.button, role: .destructive) {
                Task { await linking.forget(ask.hubID) }
            }
        } message: { ask in
            Text(ask.message)
        }
    }

    /// Every unopened Mac's one action: Forget.
    private func forget(_ item: HubListItem) -> some View {
        Button("Forget", role: .destructive) {
            asking = MacsModel.Ask(action: .forget, item: item)
        }
        .disabled(linking.isBusy)
    }
}
