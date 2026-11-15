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

/// The list's open and close and the owner's choice (#1782): a pick closes
/// the list at once and is held until the list is gone, then runs once.
struct HubSwitcherFlow: Equatable {
    var showsList = false
    private(set) var pending: HubListSheet.Choice?

    mutating func open() {
        pending = nil
        showsList = true
    }

    /// A row or Add Mac was tapped: the list closes, no Done needed.
    mutating func choose(_ choice: HubListSheet.Choice) {
        pending = choice
        showsList = false
    }

    /// On dismiss: the held choice, once (nil after a swipe down).
    mutating func takePending() -> HubListSheet.Choice? {
        defer { pending = nil }
        return pending
    }

    /// Runs a choice: another hub with a session goes on screen (the current
    /// one, or one with no session, changes nothing); Add Mac starts a scan.
    @MainActor
    static func run(_ choice: HubListSheet.Choice, env: AppEnvironment, startScan: () -> Void) {
        switch choice {
        case let .activate(hubID):
            if hubID != env.activeHubID, env.session(hubID) != nil {
                env.activate(hubID)
            }
        case .addMac:
            startScan()
        }
    }
}

private struct HubSwitcherModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    @State private var flow = HubSwitcherFlow()

    func body(content: Content) -> some View {
        content
            .environment(\.openHubList) { flow.open() }
            .sheet(isPresented: $flow.showsList, onDismiss: runPending) {
                HubListSheet { flow.choose($0) }
            }
    }

    private func runPending() {
        guard let choice = flow.takePending() else { return }
        HubSwitcherFlow.run(choice, env: env) { linking.startScan() }
    }
}
