import SwiftUI

/// The pairing sheet of Settings → Mobile over `hub pair --json --stream`
/// (go hub plan 3 Task 23, mockups §11–§13): the QR and its countdown,
/// waiting, the four-digit code with Refuse and Link, linked, each refusal.
/// The presenter starts the pairing (`start()`) and its dismissal stops it;
/// `onDone` dismisses the sheet.
struct MobilePairingSheet: View {
    typealias Copy = MobilePairingModel
    let model: MobilePairingModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Spacing.medium) {
            content
        }
        .frame(minHeight: 280)
        .multilineTextAlignment(.center)
        .padding(Spacing.wide)
        .frame(width: 380)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .starting:
            header(Copy.title)
            Text(Copy.startingText).foregroundStyle(.secondary)
            ProgressView().controlSize(.small)
            buttons { Button(Copy.cancelTitle, action: onDone).buttonStyle(.kitSecondary) }
        case .qr, .waiting:
            header(Copy.title)
            if let image = model.qrImage {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .accessibilityLabel(Copy.qrAccessibilityLabel)
                Text(Copy.scanText).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            if case .waiting = model.step {
                Text(Copy.waitingText).foregroundStyle(.secondary)
            }
            if model.showsCode {
                Text(model.countdownText).monospacedDigit().foregroundStyle(.secondary)
            }
            buttons {
                if model.showsCode {
                    Button(Copy.newCodeTitle) { Task { await model.start() } }.buttonStyle(.kitSecondary)
                }
                Button(Copy.doneTitle, action: onDone).buttonStyle(.kitSecondary).keyboardShortcut(.cancelAction)
            }
        case let .sas(code, phone):
            header(Copy.linkQuestion(phone))
            Text(Copy.checkCodeText).foregroundStyle(.secondary)
            Text(code)
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .kerning(Spacing.small)
            buttons {
                Button(Copy.refuseTitle) { Task { await model.confirm(false) } }.buttonStyle(.kitSecondary)
                Button(Copy.linkTitle) { Task { await model.confirm(true) } }.buttonStyle(.kitPrimary)
            }
        case .linked(let phone):
            header(Copy.linkedTitle(phone), tone: Tone.success)
            Text(Copy.linkedDetail).foregroundStyle(.secondary)
            buttons { Button(Copy.doneTitle, action: onDone).buttonStyle(.kitPrimary) }
        case .refused(let reason):
            header(Copy.refusalText(reason), tone: Tone.error)
            buttons {
                Button(Copy.refusalAction(reason)) { Task { await model.start() } }.buttonStyle(.kitPrimary)
                Button(Copy.doneTitle, action: onDone).buttonStyle(.kitSecondary)
            }
        case .failed(let message):
            header(Copy.unknownRefusal, tone: Tone.error)
            Text(message).font(.caption).foregroundStyle(.secondary)
            buttons {
                Button(Copy.tryAgainTitle) { Task { await model.start() } }.buttonStyle(.kitPrimary)
                Button(Copy.doneTitle, action: onDone).buttonStyle(.kitSecondary)
            }
        }
    }

    private func header(_ text: String, tone: Color = .primary) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tone)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Spacing.regular) { content() }
            .padding(.top, Spacing.regular)
    }
}
