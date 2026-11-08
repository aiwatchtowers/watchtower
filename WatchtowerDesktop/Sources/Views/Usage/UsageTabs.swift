import DesignKit
import SwiftUI
import WatchtowerCore

struct UsageTabs: View {
    @Binding var selection: UsageView.Tab

    var body: some View {
        KitSegmentedPicker(title: PlansScreenCopy.tabsTitle, selection: $selection,
                           segments: UsageView.Tab.allCases.map { KitSegment(value: $0, title: $0.title) })
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.wide)
            .padding(.top, Spacing.wide)
    }
}
