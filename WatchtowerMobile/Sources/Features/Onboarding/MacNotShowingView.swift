import SwiftUI

/// "The Mac doesn't show up" (spec §2.3 failure table): what the Mac needs
/// before it can show a code.
struct MacNotShowingView: View {
    static let checklist = [
        "Watchtower is open on the Mac",
        "Settings → Mobile is on",
        "The Mac is awake",
        "It is a signed build",
        "iCloud is on"
    ]

    var body: some View {
        ScrollView {
            SettingsCard(
                title: "Check on your Mac",
                footer: "Then choose Use Watchtower on iPhone in Settings → Mobile on the Mac, and scan the code it shows."
            ) {
                ForEach(Array(Self.checklist.enumerated()), id: \.offset) { index, item in
                    if index > 0 { CardRowDivider() }
                    HStack(spacing: Spacing.medium) {
                        Image(systemName: "\(index + 1).circle")
                            .foregroundStyle(.secondary)
                            .frame(width: PhoneMetrics.stepColumn)
                        Text(item).font(TypeScale.rowTitle)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: PhoneMetrics.minTouch, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, Spacing.large)
        }
        .navigationTitle("The Mac doesn't show up")
        .navigationBarTitleDisplayMode(.inline)
    }
}
