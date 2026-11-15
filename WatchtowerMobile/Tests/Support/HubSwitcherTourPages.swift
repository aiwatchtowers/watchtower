import SwiftUI
@testable import WatchtowerMobile

/// The switcher's states for the screenshot tour (#1782): the chip with one
/// hub, two hubs, the other hub's questions, questions spread over hubs, a hub
/// asleep and long names; the list's rows online, asleep, never heard from
/// and removed.
@MainActor
enum HubSwitcherTourPages {
    static let longName = "Engineering Build Server in the Back Office"

    private static func item(
        _ id: String, _ name: String, active: Bool = false, heartbeat: Date?, online: Bool, asks: Int = 0, removed: Bool = false
    ) -> HubListItem {
        HubListItem(
            id: id, name: name, flavor: nil, online: online, offlineDays: online ? nil : 0, openAsks: asks, isActive: active,
            removedByMac: removed, unopened: false, canForget: removed, problem: nil, lastHeartbeat: heartbeat
        )
    }

    static func rows(now: Date) -> [HubSwitcherRowModel] {
        [
            item("a", "Acme Mac", active: true, heartbeat: now, online: true, asks: 2),
            item("h", longName, heartbeat: now.addingTimeInterval(-2_400), online: false, asks: 1),
            item("n", "New Mac", heartbeat: nil, online: false),
            item("r", "Old Mac", heartbeat: now.addingTimeInterval(-86_400), online: false, asks: 3, removed: true)
        ].map { HubSwitcherRowModel($0, now: now) }
    }

    static func chips(now: Date) -> some View {
        let acme = item("a", "Acme Mac", active: true, heartbeat: now, online: true)
        let home = item("h", "Home Mac", heartbeat: now, online: true, asks: 1)
        let quietHome = item("h", "Home Mac", heartbeat: now, online: true)
        let lab = item("l", "Lab Mac", heartbeat: now, online: true, asks: 2)
        let longOther = item("y", longName, heartbeat: now, online: true, asks: 1)
        let longActive = item("x", longName, active: true, heartbeat: now.addingTimeInterval(-2_400), online: false)
        let asleep = MacChipState.asleep(lastSeen: now.addingTimeInterval(-2_400))
        func chip(_ name: String, _ state: MacChipState, _ items: [HubListItem]) -> HubSwitcherChipModel {
            HubSwitcherChipModel(name: name, state: state, items: items, now: now)
        }
        let frames: [(String, HubSwitcherChipModel)] = [
            ("One hub", chip("Acme Mac", .online, [acme])),
            ("Two hubs", chip("Acme Mac", .online, [acme, quietHome])),
            ("Other hub with questions", chip("Acme Mac", .online, [acme, home])),
            ("Spread over hubs", chip("Acme Mac", .online, [acme, home, lab])),
            ("Hub asleep", chip("Acme Mac", asleep, [acme, home])),
            ("Long name, asleep", chip(longName, asleep, [longActive, home])),
            ("Long other hub", chip("Acme Mac", .online, [acme, longOther]))
        ]
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                ForEach(frames.indices, id: \.self) { index in
                    SectionHeader(frames[index].0)
                    HubSwitcherChipView(model: frames[index].1)
                }
            }
            .padding(.horizontal, Spacing.large)
        }
        .background(Color(.systemBackground))
    }
}
