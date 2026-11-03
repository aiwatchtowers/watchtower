import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Settings → Mobile after a newer Watchtower moved the phone hub out of this
/// app (go hub phase 3 Task 2, spec §12.1): the view that release shows —
/// one section, one row, no toggle.
@MainActor
enum MobileMovedShotFixtures {
    static func screen() -> AnyView {
        AnyView(MobileMovedView(title: MobileHubMovedGuard.sectionTitle, message: MobileHubMovedGuard.message)
            .padding(.horizontal)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }
}
