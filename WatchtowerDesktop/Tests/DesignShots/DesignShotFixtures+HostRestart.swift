import SwiftUI
@testable import WatchtowerDesktop

/// The one-time v1-host restart (go hub phase 3 Task 19, mockup sections 14
/// and 15): the notice above the tabs in each state, drawn from the model's
/// `notice(for:)`, and the other workspaces' wait lines. `notNeeded` draws
/// nothing (`HostRestartStepTests.testAV2HostWithNoListNeedsNothing`).
@MainActor
enum HostRestartShotFixtures {
    static func notice(_ phase: HostRestartStep.Phase) -> AnyView {
        guard let notice = HostRestartStep.notice(for: phase) else {
            return AnyView(Text("no notice for \(String(describing: phase))"))
        }
        return AnyView(VStack(spacing: 0) {
            HostRestartNotice(notice: notice) {}
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .detailBackground())
    }

    static func waitLines() -> AnyView {
        AnyView(HostRestartWaitLines(workspaces: [
            .init(name: "acme-labs", count: 3),
            .init(name: "example", count: 1)
        ])
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }
}
