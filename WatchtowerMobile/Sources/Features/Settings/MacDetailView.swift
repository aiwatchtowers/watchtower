import os
import SwiftUI
import WatchtowerSync

/// One Mac in Settings → Macs, only while the relay is available (`MacsView.opensDetail`; a dark build never opens it):
/// its Connection section (`MacTransportModel`, mockup S08–S19, S49, S52, S54, S56) and **Forget This Mac** with the list's
/// confirmation.
struct MacDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    @Environment(\.dismiss) private var dismiss

    let hubID: String
    /// A model to show in place of the live one (the screenshot tour's frames); its actions do nothing.
    private let modelOverride: MacTransportModel?

    @State private var pressing: MacTransportModel.Action?
    @State private var asking: MacsModel.Ask?
    @State private var showsSlots = false
    @State private var showsSubscription = false

    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "MacDetail")

    init(hubID: String, model: MacTransportModel? = nil) {
        self.hubID = hubID
        modelOverride = model
    }

    /// Where a press goes: the two rows that open a screen, or the work on the hub.
    static func route(
        _ action: MacTransportModel.Action, openSubscription: () -> Void, manageMacs: () -> Void, start: (MacTransportModel.Action) -> Void
    ) {
        switch action {
        case .openSubscription: openSubscription()
        case .manageMacs: manageMacs()
        case .chooseRelay, .chooseICloud, .tryAgain: start(action)
        }
    }

    /// Only the link flow's own work holds Forget back: a switch waiting for a closed Mac never does.
    static func forgetDisabled(linkingBusy: Bool) -> Bool { linkingBusy }

    /// This phone's grant from the session's keybox; nil when it cannot be read (a locked keychain) or was not fetched yet.
    static func grant(of link: LinkRecord, session: HubSession) -> DeviceGrant? {
        guard let deviceID = link.deviceID.flatMap(UUID.init(uuidString:)) else { return nil }
        do {
            return try session.keybox(deviceID: deviceID)?.grant
        } catch {
            logger.notice("the grant was not read for the Mac's screen: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    var body: some View {
        // A closed Mac and a too-soon countdown turn by the clock alone.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .navigationDestination(isPresented: $showsSubscription) { RelaySubscriptionView() }
        .onChange(of: linking.links.contains { $0.hubID == hubID }) { _, stillLinked in
            if !stillLinked { dismiss() }
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
        .sheet(isPresented: $showsSlots, onDismiss: slotsClosed) {
            RelaySlotsView { showsSlots = false }
                .task { await linking.manageSlots(for: hubID) }
        }
        // Removing a Mac there ends the screen's run: the Connection section reads the freed slot.
        .onChange(of: linking.relaySlots.finishing) { _, finishing in
            if finishing == nil { showsSlots = false }
        }
    }

    private func slotsClosed() {
        linking.closeSlots()
        Task { await env.relayAccount?.refresh() }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let item = env.hubListItems(linking.links, unreadable: linking.unreadableHubIDs, now: now).first { $0.id == hubID }
        let link = linking.links.first { $0.hubID == hubID }?.link
        let name = item?.name ?? link?.macName ?? ""
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                if let model = model(link: link, name: name, now: now) {
                    connection(model)
                }
                if let item, MacsView.offersRemoval(backend: env.backend) {
                    forget(item)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.wide)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func model(link: LinkRecord?, name: String, now: Date) -> MacTransportModel? {
        if let modelOverride { return modelOverride }
        guard let link, let session = env.session(hubID), let center = env.relayAccount else { return nil }
        let retriesUpgrade = pressing == .tryAgain && session.transportRequest == nil
        return MacTransportModel(
            link: link, grant: Self.grant(of: link, session: session), phase: center.phase,
            unconfirmedPurchase: center.unconfirmed != nil, availability: env.relay.availability,
            session: SessionTransportFacts(
                link: link, store: session.store, now: now, pressedRelay: pressing == .chooseRelay || retriesUpgrade
            ),
            macName: name, ownDeviceID: link.deviceID, now: now
        )
    }

    private func press(_ action: MacTransportModel.Action) {
        guard modelOverride == nil else { return }
        Self.route(action, openSubscription: { showsSubscription = true }, manageMacs: { showsSlots = true }, start: { action in
            guard pressing == nil, let session = env.session(hubID) else { return }
            pressing = action
            Task {
                await MacTransportPress.run(action, session: session, center: env.relayAccount)
                pressing = nil
            }
        })
    }

    // MARK: - The section

    private func connection(_ model: MacTransportModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            SettingsCard(title: MacTransportModel.sectionTitle, footer: model.busyLine == nil ? model.footnote : nil) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows, id: \.title) { row in
                        rowView(row, model: model)
                    }
                }
                .disabled(pressing != nil)
            }
            if let busy = model.busyLine {
                busyBlock(busy, footnote: model.footnote)
            }
        }
    }

    @ViewBuilder private func rowView(_ row: MacTransportModel.Row, model: MacTransportModel) -> some View {
        let linkTitle = row.action.flatMap(MacTransportModel.title(for:))
        if let action = row.action, linkTitle == nil, row.enabled {
            Button { press(action) } label: { rowLabel(row, model: model) }
                .buttonStyle(.plain)
        } else {
            rowLabel(row, model: model)
        }
        if let action = row.action, let linkTitle {
            Button(linkTitle) { press(action) }
                .font(TypeScale.rowTitle)
                .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch, alignment: .leading)
                .foregroundStyle(PhoneTone.accent.color)
                .buttonStyle(.plain)
        }
    }

    private func rowLabel(_ row: MacTransportModel.Row, model: MacTransportModel) -> some View {
        HStack(spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(row.title)
                    .font(TypeScale.rowTitle)
                    .foregroundStyle(row.enabled || row.chosen ? .primary : .secondary)
                if let line = row.line {
                    Text(line)
                        .font(TypeScale.meta)
                        .foregroundStyle(model.tone(of: row).color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing(row)
        }
        .padding(.vertical, Spacing.regular)
        .frame(minHeight: PhoneMetrics.minTouch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.chosen ? .isSelected : [])
    }

    @ViewBuilder private func trailing(_ row: MacTransportModel.Row) -> some View {
        if row.busy {
            ProgressView().accessibilityHidden(true)
        } else if row.chosen {
            Image(systemName: "checkmark")
                .foregroundStyle(PhoneTone.accent.color)
                .accessibilityHidden(true)
        } else if row.action == .openSubscription {
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
    }

    private func busyBlock(_ line: String, footnote: String?) -> some View {
        VStack(spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                ProgressView().accessibilityHidden(true)
                Text(line)
                    .font(TypeScale.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let footnote {
                Text(footnote)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.regular)
    }

    private func forget(_ item: HubListItem) -> some View {
        Button(MacTransportModel.forgetTitle, role: .destructive) {
            asking = MacsModel.Ask(action: MacsModel.action(for: item), item: item)
        }
        .buttonStyle(SecondaryActionStyle())
        .disabled(Self.forgetDisabled(linkingBusy: linking.isBusy))
    }
}
