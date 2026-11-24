import SwiftUI
@testable import WatchtowerDesktop

/// The mockup of the Link confirmation with the Relay warning (#2191 Task 6
/// Step 4): `MobilePairingSheet`'s `.sas` layout from kit parts, plus the
/// warning line as the sheet will draw it — a caption in `Tone.warning`
/// under the check line, wrapping inside the 380 pt sheet. Deleted once the
/// sheet draws the line itself (Step 6).
struct MobilePairingWarningMockup: View {
    typealias Copy = MobilePairingModel
    let model: MobilePairingModel

    var body: some View {
        VStack(spacing: Spacing.medium) {
            if case let .sas(code, phone) = model.step {
                Text(Copy.linkQuestion(phone))
                    .font(.title3.weight(.semibold))
                Text(Copy.checkCodeText).foregroundStyle(.secondary)
                if let warning = model.relayMoveWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(Tone.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(code)
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                    .kerning(Spacing.small)
                HStack(spacing: Spacing.regular) {
                    Button(Copy.refuseTitle) {}.buttonStyle(.kitSecondary)
                    Button(Copy.linkTitle) {}.buttonStyle(.kitPrimary)
                }
                .padding(.top, Spacing.regular)
            }
        }
        .frame(minHeight: 280)
        .multilineTextAlignment(.center)
        .padding(Spacing.wide)
        .frame(width: 380)
    }
}
