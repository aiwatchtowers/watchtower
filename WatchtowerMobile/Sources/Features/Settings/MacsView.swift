import SwiftUI

/// Settings → Macs (multi-hub spec §5.6): the linked Macs in order, reordered
/// with Edit, each Unlinked or Forgotten (`MacsModel.action`) from its swipe
/// action or context menu; Add Mac at the bottom as in the switcher.
struct MacsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    /// The Mac the owner is asked about, and what is asked.
    @State private var asking: MacsModel.Ask?
    /// The finishing link whose Cancel is being confirmed.
    @State private var cancelling: MacsModel.FinishingRow?
    /// The finishing link whose Manage Macs is open.
    @State private var managing: MacsModel.FinishingRow?

    /// `cancelling`: a finishing link's Cancel confirmation already open (the screenshot tour's frame).
    /// Opened once the screen is on (an alert set before it has a window is not presented).
    private let initialCancel: MacsModel.FinishingRow?

    init(cancelling: MacsModel.FinishingRow? = nil) {
        initialCancel = cancelling
    }

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
        // An alert: both Cancel Link and Keep Trying show at every width (mockup 7.4).
        .alert(
            cancelling.map { MacsModel.cancelQuestion($0.name) } ?? "",
            isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
            presenting: cancelling
        ) { row in
            Button(MacsModel.cancelLink, role: .destructive) {
                Task { await linking.cancelPromoted(row.id) }
            }
            Button(MacsModel.keepTrying, role: .cancel) {}
        }
        .task {
            if let initialCancel { cancelling = initialCancel }
        }
        .sheet(item: $managing) { row in
            RelaySlotsView { managing = nil; linking.closeSlots() }
                .task { await linking.manageSlots(for: row.id) }
        }
    }

    private func list(_ items: [HubListItem]) -> some View {
        let canAdd = HubListModel.canAddMac(rows: linking.links, unreadable: linking.unreadableHubIDs)
        return List {
            Section {
                ForEach(items) { item in
                    HubListRow(item: item)
                        .macsListRow()
                        .swipeActions(edge: .trailing) { actions(item) }
                        .contextMenu { actions(item) }
                }
                .onMove { source, destination in
                    move(items, from: source, to: destination)
                }
                .moveDisabled(linking.isBusy)
                ForEach(MacsModel.finishingRows(
                    linking.promotedLinks, running: linking.resumer.running, failed: linking.resumer.failed
                )) { row in
                    FinishingLinkRow(row: row) { action in
                        switch action {
                        case .manageMacs: managing = row
                        case .tryAgain: Task { await linking.tryAgain(row.id) }
                        case .cancel: cancelling = row
                        }
                    }
                    .macsListRow()
                }
            }
            if Self.offersAdd(backend: env.backend) {
                Section {
                    Button {
                        linking.startScan()
                    } label: {
                        Label("Add Mac", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(SecondaryActionStyle())
                    .disabled(!canAdd || linking.isBusy)
                    .macsListRow()
                    if !canAdd {
                        Text("You can link up to \(HubRegistry.limit) Macs")
                            .font(TypeScale.meta)
                            .foregroundStyle(.secondary)
                            .macsListRow()
                    }
                }
            }
        }
        .macsList()
    }

    /// The demo has no link to end: only a live build offers Unlink and
    /// Forget; reorder stays in both.
    static func offersRemoval(backend: SessionBackend) -> Bool {
        backend != .inMemoryDemo
    }

    /// Nor a link to make: a scan in the demo would run the real link flow
    /// against the owner's iCloud (the signed build's tour, #174) before
    /// failing, so only a live build offers Add Mac.
    static func offersAdd(backend: SessionBackend) -> Bool {
        backend != .inMemoryDemo
    }

    /// The row's one destructive action (`MacsModel.action`).
    @ViewBuilder private func actions(_ item: HubListItem) -> some View {
        if Self.offersRemoval(backend: env.backend) {
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

/// A confirmed Relay link still finishing (mockup 7.4): its line, a spinner while an attempt runs, and its
/// actions (Manage Macs, Try Again, Cancel) as quiet buttons. Never a blocking screen.
struct FinishingLinkRow: View {
    let row: MacsModel.FinishingRow
    let act: (MacsModel.FinishingRow.Action) -> Void

    var body: some View {
        FlatRow(icon: .symbol("laptopcomputer", tone: .secondary), title: row.name, titleLineLimit: 1, insets: EdgeInsets()) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(row.line)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = row.note {
                    Text(note)
                }
                if !row.actions.isEmpty {
                    // One line when it fits; stacked at the larger text sizes.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.regular) { actionButtons }
                        VStack(alignment: .leading, spacing: Spacing.regular) { actionButtons }
                    }
                    .padding(.top, Spacing.tight)
                }
            }
        } trailing: {
            if row.showsProgress {
                ProgressView()
            }
        }
    }

    private var actionButtons: some View {
        ForEach(row.actions, id: \.title) { action in
            Button(action.title) { act(action) }
                .buttonStyle(BannerButtonStyle())
        }
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
                            .macsListRow()
                            .swipeActions(edge: .trailing) { forget(item) }
                            .contextMenu { forget(item) }
                    }
                } header: {
                    Text("Watchtower couldn't open the data of these Macs on this iPhone. Try again, or forget a Mac and link it again.")
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
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
                    .buttonStyle(ProminentActionStyle())
                    .disabled(retrying || linking.isBusy)
                    .macsListRow()
                    Button {
                        linking.startScan()
                    } label: {
                        Label("Add Mac", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(SecondaryActionStyle())
                    .disabled(!canAdd || linking.isBusy)
                    .macsListRow()
                }
            }
            .macsList()
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

extension View {
    /// The Macs lists' look (Settings → Macs, the switcher's sheet, the
    /// unopened Macs): flat rows on the page, no grouped fill.
    func macsList() -> some View {
        listStyle(.plain).scrollContentBackground(.hidden)
    }

    /// One row of such a list: the flat row's insets, no separator or plate.
    func macsListRow() -> some View {
        listRowInsets(RowInsets.flat).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}
