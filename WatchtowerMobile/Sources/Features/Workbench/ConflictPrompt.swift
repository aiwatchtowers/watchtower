import SwiftUI

/// "Changed on your tower to X — apply anyway?" with Yes (send again over the
/// Mac's value) and No (drop the change): the design system's prominent and
/// secondary buttons sharing the width.
struct ConflictPrompt: View {
    let prompt: String
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(prompt).font(.subheadline)
            HStack(spacing: Spacing.medium) {
                Button("Yes", action: onYes)
                    .buttonStyle(ProminentActionStyle())
                    .accessibilityLabel("Yes, apply anyway")
                Button("No", role: .cancel, action: onNo)
                    .buttonStyle(SecondaryActionStyle())
                    .accessibilityLabel("No, keep the tower's value")
            }
        }
        .padding(.vertical, Spacing.small)
    }
}

/// One of the phone's board writes the Mac has not applied: its request,
/// then "Sending…" / "Waiting for your Mac", the Mac's refusal with
/// Dismiss, or the conflict prompt. Flat: the caller puts it on a card.
struct BoardWriteRowView: View {
    let row: BoardWriteRow
    let onApplyAnyway: (BoardWriteRow) -> Void
    let onDismiss: (BoardWriteRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(row.title).font(TypeScale.rowTitle)
            BoardWriteCaption(state: row.state, onApplyAnyway: { onApplyAnyway(row) }, onDismiss: { onDismiss(row) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.borderless)
    }
}

/// A board write's state line: "Sending…" / "Waiting for your tower" in the
/// secondary tone, the refusal in red with Dismiss, or the conflict prompt.
/// Under a write row, and under a board card for the phone's own change
/// (live link R5).
struct BoardWriteCaption: View {
    let state: BoardWriteRow.State
    let onApplyAnyway: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        switch state {
        case let .sending(caption):
            Label(caption, systemImage: "clock")
                .font(TypeScale.meta)
                .foregroundStyle(.secondary)
        case let .failed(message):
            HStack(alignment: .firstTextBaseline) {
                Text(message)
                    .font(TypeScale.meta)
                    .foregroundStyle(PhoneTone.red.color)
                Spacer(minLength: Spacing.regular)
                Button(action: onDismiss) {
                    Text("Dismiss")
                        .frame(minHeight: PhoneMetrics.minTouch)
                        .contentShape(Rectangle())
                }
                .font(TypeScale.meta)
                .accessibilityLabel("Dismiss the failed change")
            }
        case let .conflict(prompt):
            ConflictPrompt(prompt: prompt, onYes: onApplyAnyway, onNo: onDismiss)
        }
    }
}
