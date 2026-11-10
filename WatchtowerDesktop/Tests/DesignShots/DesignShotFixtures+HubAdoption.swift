import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Settings → Mobile while Mobile moves to the Go hub (go hub plan 3 Task 22,
/// mockup sections 4–6): the real view in each shown state. `notNeeded` and
/// `done` draw the regular tab (`HubAdoptionStateTests.testShownStates`).
@MainActor
enum HubAdoptionShotFixtures {
    static func screen(_ state: HubAdoptionState) -> AnyView {
        AnyView(MobileHandOverView(state: state) {}
            .padding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }
}
