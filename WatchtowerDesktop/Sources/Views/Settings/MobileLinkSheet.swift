import SwiftUI

/// The QR sheet of Settings → Mobile: the `watchtower://link` code, its
/// countdown and New code (mobile POC spec §2.3). `onDone` dismisses the
/// sheet; the presenter's dismissal closes the link.
struct MobileLinkSheet: View {
    let model: MobileLinkSheetViewModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Use Watchtower on iPhone")
                .font(.title2.weight(.semibold))
            content
                .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .task { await model.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .issuing:
            ProgressView("Making a code…")
        case .showing where !model.pendingLinks.isEmpty:
            VStack(spacing: 12) {
                ForEach(model.pendingLinks) { link in
                    PendingLinkRow(link: link, model: model)
                }
                if let error = model.decisionError {
                    Text(error)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Text("Expires in \(model.countdownText)")
                    .monospacedDigit()
            }
        case .showing:
            VStack(spacing: 12) {
                if let image = model.qrImage {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .accessibilityLabel("Link code")
                }
                Text("Scan it with the iPhone camera or the Watchtower app.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Expires in \(model.countdownText)")
                    .monospacedDigit()
                Button("New code") { Task { await model.newCode() } }
            }
        case .expired:
            VStack(spacing: 12) {
                Text("This code expired.")
                Button("Show a new code") { Task { await model.newCode() } }
            }
        case .linked(let name):
            Label("Linked \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.newCode() } }
            }
        }
    }
}

/// One phone waiting for the owner (mobile E2E spec §2.3): its name, the
/// four-digit code both screens show, Link and Refuse.
struct PendingLinkRow: View {
    let link: MobileLinkCenter.PendingLink
    let model: MobileLinkSheetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Link \"\(link.name)\"?")
                .font(.headline)
            Text("Code \(link.sas) — check that your iPhone shows the same code")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Refuse") { Task { await model.refuse(link) } }
                Button("Link") { Task { await model.confirm(link) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
