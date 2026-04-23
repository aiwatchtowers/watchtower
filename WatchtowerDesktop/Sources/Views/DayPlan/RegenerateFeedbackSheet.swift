import SwiftUI

struct RegenerateFeedbackSheet: View {
    @Bindable var vm: DayPlanViewModel
    @Binding var isPresented: Bool

    @State private var feedback: String = ""

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            formContent
            Divider()
            sheetFooter
        }
        .frame(width: 460, height: 380)
        .onAppear {
            feedback = vm.feedbackDraft
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            Text("Regenerate with feedback")
                .font(.headline)
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Form

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Feedback editor
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tell me what to change:")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    TextEditor(text: $feedback)
                        .font(.callout)
                        .frame(minHeight: 120)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }

                // Recent feedback history
                let history = vm.plan?.parsedFeedbackHistory ?? []
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recent feedback:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fontWeight(.medium)

                        ForEach(Array(history.suffix(3).reversed().enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 1)
                                Text(entry)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                // Info text
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("Your manually added items will be preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack {
            Spacer()
            Button("Regenerate") {
                let fb = feedback
                Task {
                    await vm.regenerate(feedback: fb)
                    isPresented = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isGenerating)
        }
        .padding()
    }
}
