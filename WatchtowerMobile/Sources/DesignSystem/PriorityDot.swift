import SwiftUI
import WatchtowerKit

/// Which priorities get a dot (design pass spec §2.4): high red, low blue.
/// Medium, the default, gets none: the Mac marks it orange, and the phone's
/// orange is only for waiting and asks.
enum PriorityMark {
    static func tone(_ priority: WorkbenchTargetPriority) -> PhoneTone? {
        switch priority {
        case .high: .red
        case .low: .blue
        default: nil
        }
    }

    static func accessibilityLabel(_ priority: WorkbenchTargetPriority) -> String? {
        switch priority {
        case .high: "High priority"
        case .low: "Low priority"
        default: nil
        }
    }
}

/// A 6 pt priority dot (the Mac's `TargetsListView.swift:516-529`); nothing,
/// and no reserved space, without a tone. It sits first in a row's meta
/// line.
struct PriorityDot: View {
    let priority: WorkbenchTargetPriority

    var body: some View {
        if let tone = PriorityMark.tone(priority) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
                .accessibilityLabel(PriorityMark.accessibilityLabel(priority) ?? "")
        }
    }
}
