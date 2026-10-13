import SwiftUI

/// The Mac switcher's chip (multi-hub spec §5.6): the active Mac's name in
/// the leading toolbar slot of Now and Workbench, with the open asks waiting
/// on the other Macs beside it. Shown with one linked Mac too: it is the way
/// to Add Mac.
struct HubSwitcherChip: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LinkingViewModel.self) private var linking
    let action: () -> Void

    var body: some View {
        // Names and asks only: no clock-driven field is read here.
        let items = env.hubListItems(linking.links, now: .now)
        let name = items.first(where: \.isActive)?.name ?? env.active?.hubName ?? "Mac"
        let otherAsks = HubListModel.otherHubsOpenAsks(items)
        Button(action: action) {
            HStack(spacing: Spacing.small) {
                Pill(text: name, tone: .accent)
                Image(systemName: "chevron.down")
                    .font(TypeScale.badge)
                    .foregroundStyle(PhoneTone.accent.color)
                if otherAsks > 0 {
                    CountBadge(count: otherAsks, tone: .waitingForYou)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(HubListModel.chipAccessibilityLabel(name: name, otherAsks: otherAsks))
        .accessibilityHint("Shows your Macs")
    }
}

extension View {
    /// The switcher chip in the leading toolbar slot and the list of Macs it
    /// opens. The list's choice runs once the sheet is gone: a switch
    /// rebuilds the tabs (and with them this view), and a scan's cover
    /// cannot rise over a sheet still on screen.
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HubSwitcherChip { showsList = true }
                }
            }
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
