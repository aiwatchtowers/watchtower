import SwiftUI
import WatchtowerCore

/// "Run “<name>”?" (approved mockup 6, second step): shown before a
/// `confirm: true` recipe picked in the "Run Automation…" palette runs.
/// Nothing runs until **Run**; **Cancel** (or esc) runs nothing. A refusal
/// keeps the sheet up with the CLI's message.
struct QuickRunConfirmSheet: View {
    let row: QuickRunRow
    @Bindable var center: QuickRunCenter
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run “\(row.name)”?")
                .font(.headline)
            if !row.descriptionLead.isEmpty {
                Text(row.descriptionLead)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("You'll get a notice when it ends.")
                .foregroundStyle(.secondary)
            if let error = center.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { center.cancelConfirm() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") {
                    running = true
                    Task {
                        await center.confirmRun()
                        running = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(running)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
    }
}
