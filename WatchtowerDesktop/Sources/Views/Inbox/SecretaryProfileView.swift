import SwiftUI

// MARK: - SecretaryProfileView

/// Inbox → Profile tab: the secretary brief plus the communication style
/// profile. Both are workspace-level free text; the style profile can also be
/// regenerated from the owner's own messages via `watchtower inbox style-sample`.
struct SecretaryProfileView: View {
    @Bindable var vm: SecretaryProfileViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage = vm.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if vm.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        briefSection
                        styleSection
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { vm.load() }
    }

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Who you are")
                .font(.headline)
            Text("Tell the assistant who you are and what matters. It reads this before every scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
            editor(text: $vm.briefText, minHeight: 160)
            HStack {
                Spacer()
                Button("Save") { Task { await vm.saveBrief() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isSavingBrief || vm.isLoading)
            }
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Communication style")
                .font(.headline)
            Text(
                "How you write on Slack — used by Discuss to draft replies in your voice. "
                    + "Generate a starting point from your own messages, then edit freely."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            editor(text: $vm.styleText, minHeight: 200)
            HStack {
                Button {
                    Task { await vm.generateStyle() }
                } label: {
                    if vm.isGenerating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Generating…")
                        }
                    } else {
                        Label("Generate from my messages", systemImage: "wand.and.stars")
                    }
                }
                .disabled(!vm.canGenerate)
                .help(vm.hasUnsavedStyleChanges
                      ? "Save or revert your edits first — generating would overwrite them"
                      : "Analyze your recent Slack messages and write a style profile")
                Spacer()
                Button("Save") { Task { await vm.saveStyle() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isSavingStyle || vm.isLoading || !vm.hasUnsavedStyleChanges)
            }
        }
    }

    private func editor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: minHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}
