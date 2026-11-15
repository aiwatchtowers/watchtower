import SwiftUI

/// The switcher chip at the top of Now, Workbenches and the Calendar (#1782):
/// the hub on screen's status chip, with a ▾ and the list on a tap when more
/// than one hub is linked, and the questions waiting on the other hubs in
/// words. Texts from `HubSwitcherChipModel`.
struct HubSwitcherChip: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    let now: Date

    var body: some View {
        let items = env.hubListItems(linking.links, unreadable: linking.unreadableHubIDs, now: now)
        let name = items.first(where: \.isActive)?.name ?? env.workbenchReplica.snapshot.heartbeat?.macName ?? ""
        let state = env.macReachability(now: now).chipState(linked: env.linkedDevice != nil)
        HubSwitcherChipView(model: HubSwitcherChipModel(name: name, state: state, items: items, now: now))
    }
}

/// The chip itself over its model; a button only while it switches and a
/// `hubSwitcher()` above it can open the list.
struct HubSwitcherChipView: View {
    @Environment(\.openHubList) private var openHubList
    let model: HubSwitcherChipModel

    var body: some View {
        if model.switches, let openHubList {
            Button(action: openHubList) { label }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.accessibilityLabel)
                .accessibilityHint(HubSwitcherText.chipHint)
                .accessibilityAddTraits(.isButton)
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.accessibilityLabel)
        }
    }

    private var label: some View {
        // Side by side while it fits; the questions go under the chip on a
        // narrow screen, a long name or large text.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.regular) { capsule; asks }
            VStack(alignment: .leading, spacing: Spacing.tight) { capsule; asks }
        }
        .contentShape(Rectangle())
    }

    private var capsule: some View {
        MacStatusChip(model: model.status, opensList: model.switches)
    }

    @ViewBuilder private var asks: some View {
        if let otherAsks = model.otherAsks {
            Text(otherAsks)
                .font(TypeScale.meta)
                .foregroundStyle(PhoneTone.waitingForYou.color)
                .lineLimit(1)
        }
    }
}

extension EnvironmentValues {
    /// Opens the switcher's list; set by `hubSwitcher()`, nil outside it.
    @Entry var openHubList: (@MainActor () -> Void)?
}

extension View {
    /// The list of linked hubs the switcher chip below opens. The list's
    /// choice runs once the sheet is gone: a switch rebuilds the tabs (and
    /// with them this view), and a scan's cover cannot rise over a sheet
    /// still on screen.
    func hubSwitcher() -> some View {
        modifier(HubSwitcherModifier())
    }
}

private struct HubSwitcherModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    @State private var showsList = false
    @State private var pending: HubListSheet.Choice?

    func body(content: Content) -> some View {
        content
            .environment(\.openHubList) { showsList = true }
            .sheet(isPresented: $showsList, onDismiss: runPending) {
                HubListSheet { choice in
                    pending = choice
                    showsList = false
                }
            }
    }

    private func runPending() {
        guard let choice = pending else { return }
        pending = nil
        switch choice {
        case let .activate(hubID):
            if hubID != env.activeHubID, env.session(hubID) != nil {
                env.activate(hubID)
            }
        case .addMac:
            linking.startScan()
        }
    }
}
