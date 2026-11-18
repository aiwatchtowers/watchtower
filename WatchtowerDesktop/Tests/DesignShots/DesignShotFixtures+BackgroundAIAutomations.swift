import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

// MARK: - The real Automations notice and rows, beside their mockups (Task 16)

extension BackgroundAIConsentShotFixtures {
    static var automationsLiveShots: [DesignShot] {
        [
            DesignShot(name: "ai-consent-automations-live-paused", size: NSSize(width: 720, height: 0)) {
                AnyView(LiveAutomationsNotice(state: BackgroundAIConsent.resolve(answer: "paused", policy: nil)))
            },
            DesignShot(name: "ai-consent-automations-live-org", size: NSSize(width: 720, height: 0)) {
                AnyView(LiveAutomationsNotice(state: BackgroundAIConsent.resolve(answer: nil, policy: false)))
            }
        ]
    }
}

/// The list column's top as `AutomationsView` lays it out: the notice card,
/// then real rows. Sample data only (`acme`).
private struct LiveAutomationsNotice: View {
    let state: BackgroundAIConsent.State

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func item(
        _ id: Int64, _ name: String, trigger: String, permissions: [String], when: String
    ) -> AutomationListItem {
        let automation = Automation(
            id: id, slug: "a\(id)", name: name, triggerKind: trigger, permissions: permissions,
            approvalHash: "h", confirmedHash: "h", enabled: true, nextRunAt: now.addingTimeInterval(3600)
        )
        return AutomationListItem(
            automation: automation, lastRun: nil, activeRun: nil, tokens7d: 0,
            badges: AutomationListItem.badges(for: automation, grants: []), triggerText: when
        )
    }

    private let items = [
        item(1, "Morning brief", trigger: "schedule", permissions: ["llm:strong"], when: "Every day at 08:00"),
        item(2, "Weekly status for acme", trigger: "schedule", permissions: ["agent:run"], when: "Fridays at 16:00"),
        item(3, "Archive old exports", trigger: "schedule", permissions: ["shell:archive"], when: "Every day at 02:00")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if let notice = AutomationsBackgroundAINotice.make(state: state, items: items) {
                AutomationsBackgroundAINoticeCard(notice: notice) {}
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    AutomationListRow(
                        item: item, changes: nil, isSelected: false, now: Self.now, backgroundAI: state
                    ) {}
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}
