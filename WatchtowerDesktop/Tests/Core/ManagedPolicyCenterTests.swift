import Foundation
import Testing
@testable import WatchtowerCore

@MainActor
@Suite("ManagedPolicyCenter")
struct ManagedPolicyCenterTests {
    @Test("refresh publishes only a change")
    func refreshPublishesOnlyOnChange() {
        var raw: [String: Any] = ["MobileSync": "off"]
        let center = ManagedPolicyCenter { raw }
        var changes = 0
        center.onChange = { _ in changes += 1 }
        center.refresh()
        center.refresh()
        #expect(changes == 1)
        #expect(center.policy.mobileSyncMode == "off")
        raw["MobileSync"] = "workbench_only"
        center.refresh()
        #expect(changes == 2)
    }

    @Test("a profile removed while running unlocks every key")
    func profileRemovedUnlocks() {
        var raw: [String: Any] = ["AllowedSources": ["slack"], "AllowAutomationShell": false, "RetentionDays": 30]
        let center = ManagedPolicyCenter { raw }
        center.refresh()
        #expect(center.policy.isLocked(.allowedSources))
        #expect(center.policy.isLocked(.retentionDays))
        raw = [:]
        center.refresh()
        #expect(center.policy == .none)
        #expect(ManagedPolicy.Key.allCases.allSatisfy { !center.policy.isLocked($0) })
    }

    @Test("start refreshes at once and on each activation")
    func startRefreshesOnActivation() {
        var reads = 0
        let center = ManagedPolicyCenter { reads += 1; return [:] }
        let notifications = NotificationCenter()
        let activation = Notification.Name("test.activation")
        center.start(activation: activation, center: notifications, queue: nil, interval: 3600)
        #expect(reads == 1)
        notifications.post(name: activation, object: nil)
        #expect(reads == 2)
        center.stop()
        notifications.post(name: activation, object: nil)
        #expect(reads == 2)
    }
}
