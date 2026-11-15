import SwiftUI

/// "The tower doesn't show up" (spec §2.3 failure table): what a Mac or a
/// server needs before it can show a code (#1783: the phone does not know
/// yet which one it links to, so both checklists show).
struct MacNotShowingView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                checklist(PairingText.macTitle, PairingText.macChecklist, footer: PairingText.macFooter)
                checklist(PairingText.serverTitle, PairingText.serverChecklist, footer: PairingText.serverFooter)
            }
            .padding(.horizontal, Spacing.large)
        }
        .navigationTitle(PairingText.notShowingLink)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func checklist(_ title: String, _ items: [String], footer: String) -> some View {
        SettingsCard(title: title, footer: footer) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
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
    }
}
