import SwiftUI
import GRDB

// MARK: - SecretaryProfileView

/// Editor for `workspace.secretary_profile` — the free-text brief the secretary
/// pipeline reads before every inbox scan.
struct SecretaryProfileView: View {
    let db: DatabasePool

    @State private var text = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showSaved = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tell the secretary who you are and what matters. It reads this before every scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    if showSaved {
                        Text("Saved")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || isLoading)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .task { load() }
    }

    // MARK: - Data Loading

    private func load() {
        isLoading = true
        Task {
            do {
                let fetched = try await db.read { dbConn in
                    try SecretaryProfileQueries.fetch(dbConn)
                }
                text = fetched
                isLoading = false
            } catch {
                errorMessage = "Failed to load: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        let toSave = text
        Task {
            do {
                try await db.write { dbConn in
                    try SecretaryProfileQueries.save(dbConn, text: toSave)
                }
                isSaving = false
                withAnimation { showSaved = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { showSaved = false }
            } catch {
                errorMessage = "Save failed: \(error.localizedDescription)"
                isSaving = false
            }
        }
    }
}
