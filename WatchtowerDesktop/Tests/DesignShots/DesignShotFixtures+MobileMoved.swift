import SwiftUI
import WatchtowerSync
@testable import WatchtowerDesktop

/// Settings → Mobile after a newer Watchtower moved the phone hub out of this
/// app (go hub phase 3 Task 2, spec §12.1): the real view over a host whose
/// `MobileHub/` holds the `MOVED` note — one section, one row, no toggle.
@MainActor
enum MobileMovedShotFixtures {
    static func screen() -> AnyView {
        let host = FakeMobileSettingsHost(enabled: true)
        host.isMobileHubMoved = true
        let model = MobileSettingsViewModel(host: host, entitlementPresent: true, flavor: .default)
        return AnyView(MobileSettingsView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }
}
