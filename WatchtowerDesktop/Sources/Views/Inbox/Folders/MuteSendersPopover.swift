import SwiftUI
import WatchtowerCore

/// **Mute Senders…** in Mail waiting's pane header and the popover anchored
/// to it (spec "Waiting for me and Mail waiting", mockup "Mute Senders…
/// open"). Each opening reads the senders afresh with none ticked.
struct MuteSendersButton: View {
    /// Reads the busiest unmuted senders (`ActionStripViewModel.muteSenderCandidates`).
    let load: () async throws -> [MailSenderRow]
    /// Writes one sender's mute (`ActionStripViewModel.writeSenderMute`).
    let mute: (String) async throws -> Void
    /// After a press: re-reads the Inbox (the muted senders leave Mail waiting).
    let onFinished: () async -> Void

    @State private var isOpen = false

    var body: some View {
        Button("Mute Senders…") { isOpen.toggle() }
            .buttonStyle(.kitSecondary)
            .accessibilityIdentifier("inbox.paneHeader.muteSenders")
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                MuteSendersPopover(load: load, mute: mute) { result in
                    await onFinished()
                    if case .done = result { isOpen = false }
                }
                .popoverSurface()
            }
    }
}

/// The popover's body: the ten busiest senders with a checkbox and their open
/// count, one prominent **Mute N Senders**, and "Muted N of M. <error>" under
/// it when a press stopped part-way.
struct MuteSendersPopover: View {
    @StateObject private var model: MuteSendersModel
    let onApplied: (MuteSendersResult) async -> Void

    init(
        load: @escaping () async throws -> [MailSenderRow],
        mute: @escaping (String) async throws -> Void,
        onApplied: @escaping (MuteSendersResult) async -> Void
    ) {
        _model = StateObject(wrappedValue: MuteSendersModel(load: load, mute: mute))
        self.onApplied = onApplied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Mute senders")
                .font(.headline)
            Text("The ten busiest senders in Mail waiting. A muted sender leaves Mail waiting only; its mail stays where it is.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            senders
            HStack(spacing: Spacing.regular) {
                Spacer(minLength: 0)
                if model.isApplying { ProgressView().controlSize(.small) }
                Button(model.buttonTitle) {
                    Task {
                        let result = await model.apply()
                        await onApplied(result)
                    }
                }
                .buttonStyle(.kitPrimary)
                .disabled(!model.canApply)
                .accessibilityIdentifier("inbox.muteSenders.apply")
            }
            .padding(.top, Spacing.small)
            if let line = model.failureLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("inbox.muteSenders.error")
            }
        }
        .controlSize(.small)
        .padding(Spacing.medium)
        .frame(width: PaneWidth.sideListMax)
        .task { await model.load() }
    }

    @ViewBuilder
    private var senders: some View {
        if model.isLoading && model.rows.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else if let error = model.loadError {
            Text("Couldn't read the senders. \(error)")
                .font(.caption)
                .foregroundStyle(Tone.error)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if model.rows.isEmpty {
            Text("No sender to mute.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows, id: \.address) { row in
                    Toggle(isOn: ticked(row.address)) {
                        HStack(spacing: Spacing.regular) {
                            Text(row.address)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: Spacing.regular)
                            Text("\(row.open) open")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(model.isApplying)
                    .kitRow(isSelected: false)
                }
            }
        }
    }

    private func ticked(_ address: String) -> Binding<Bool> {
        Binding(
            get: { model.selected.contains(address) },
            set: { on in
                if on { model.selected.insert(address) } else { model.selected.remove(address) }
            })
    }
}
