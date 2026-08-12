import Foundation
import GRDB
import WatchtowerCore

/// Drives the Inbox → Profile tab: the secretary brief editor plus the
/// communication style profile (editable text + on-demand regeneration via
/// `watchtower inbox style-sample`). Owned by AppState so an in-flight
/// generation survives tab/sidebar navigation.
@MainActor
@Observable
final class SecretaryProfileViewModel {
    var briefText = ""
    var styleText = ""
    private(set) var styleUpdatedAt = ""
    var isLoading = false
    var isSavingBrief = false
    var isSavingStyle = false
    var isGenerating = false
    var errorMessage: String?

    /// The style text as last loaded/saved — the baseline for unsaved-change detection.
    private var loadedStyleText = ""

    private let dbManager: DatabaseManager
    private let cliRunner: CLIRunnerProtocol?

    init(dbManager: DatabaseManager, cliRunner: CLIRunnerProtocol? = nil) {
        self.dbManager = dbManager
        self.cliRunner = cliRunner
    }

    var hasUnsavedStyleChanges: Bool { styleText != loadedStyleText }

    /// Generate overwrites the stored profile; refuse while the editor holds
    /// unsaved manual edits so they are never silently clobbered.
    var canGenerate: Bool { !isGenerating && !hasUnsavedStyleChanges }

    func load() {
        isLoading = true
        do {
            let (brief, style) = try dbManager.dbPool.read { db in
                (try SecretaryProfileQueries.fetch(db), try SecretaryProfileQueries.fetchStyle(db))
            }
            briefText = brief
            styleText = style.text
            loadedStyleText = style.text
            styleUpdatedAt = style.updatedAt
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load profile: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func saveBrief() async {
        isSavingBrief = true
        defer { isSavingBrief = false }
        do {
            let text = briefText
            try await dbManager.dbPool.write { db in
                try SecretaryProfileQueries.save(db, text: text)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func saveStyle() async {
        isSavingStyle = true
        defer { isSavingStyle = false }
        do {
            let text = styleText
            try await dbManager.dbPool.write { db in
                try SecretaryProfileQueries.saveStyle(db, text: text)
            }
            loadedStyleText = text
            errorMessage = nil
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Runs `watchtower inbox style-sample` and reloads. Guarded against
    /// re-entry and against clobbering unsaved manual edits.
    func generateStyle() async {
        guard canGenerate else { return }
        isGenerating = true
        defer { isGenerating = false }
        guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return
        }
        do {
            _ = try await runner.run(args: ["inbox", "style-sample"])
            load()
        } catch {
            errorMessage = "Failed to generate style profile: \(error.localizedDescription)"
        }
    }
}
