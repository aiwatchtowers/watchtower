import SwiftUI

/// "Changed on the Mac to X — apply anyway?" with Yes (send again over the
/// Mac's value) and No (drop the change).
struct ConflictPrompt: View {
    let prompt: String
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt).font(.subheadline)
            HStack(spacing: 12) {
                Button("Yes", action: onYes)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Yes, apply anyway")
                Button("No", role: .cancel, action: onNo)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("No, keep the Mac's value")
            }
            // Large size: each button itself is at least 44 pt tall.
            .controlSize(.large)
        }
        .padding(.vertical, 4)
    }
}

/// One of the phone's board writes the Mac has not applied: its request,
/// then "Sending…" / "Waiting for your Mac", the Mac's refusal with
/// Dismiss, or the conflict prompt.
struct BoardWriteRowView: View {
    let row: BoardWriteRow
    let onApplyAnyway: (BoardWriteRow) -> Void
    let onDismiss: (BoardWriteRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title).font(.subheadline)
            switch row.state {
            case let .sending(caption):
                Label(caption, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .failed(message):
                HStack(alignment: .firstTextBaseline) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(PhoneTone.red.color)
                    Spacer(minLength: 8)
                    Button { onDismiss(row) } label: {
                        Text("Dismiss")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .font(.caption)
                    .accessibilityLabel("Dismiss the failed change")
                }
            case let .conflict(prompt):
                ConflictPrompt(prompt: prompt, onYes: { onApplyAnyway(row) }, onNo: { onDismiss(row) })
            }
        }
        .buttonStyle(.borderless)
    }
}
