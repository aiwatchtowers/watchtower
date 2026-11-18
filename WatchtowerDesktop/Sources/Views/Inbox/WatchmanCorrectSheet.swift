import SwiftUI
import WatchtowerCore

/// Correct… (spec §10, D26; mockup `watchman-journal-correct-sheet`): the
/// owner writes what he would have decided. Send Correction stores it, then
/// types it into the live session or starts a new one with it.
struct WatchmanCorrectSheet: View {
    @Bindable var model: WatchmanJournalViewModel

    var body: some View {
        if let draft = model.correcting {
            content(draft)
        }
    }

    private func content(_ draft: WatchmanJournalViewModel.CorrectDraft) -> some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            Text(model.sheetTitle).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(draft.question).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let choice = draft.choice {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                        Text(model.choseLabel).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(choice).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(model.sheetQuestion).font(.headline)
                TextField("", text: textBinding, axis: .vertical)
                    .textFieldStyle(.kit)
                    .lineLimit(3...6)
                    .disabled(draft.saving)
                HStack(alignment: .top, spacing: Spacing.regular) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(draft.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = draft.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Tone.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button(model.cancelTitle) { model.cancelCorrect() }
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(!draft.canCancel)
                Button(model.sendTitle) { Task { await model.sendCorrection() } }
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSend)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(width: Self.width, alignment: .topLeading)
        .detailBackground()
        .interactiveDismissDisabled(!draft.canCancel)
    }

    /// The sheet's width (the mockup's).
    static let width: CGFloat = 480

    private var textBinding: Binding<String> {
        Binding(get: { model.correcting?.text ?? "" }, set: { model.correcting?.text = $0 })
    }
}
