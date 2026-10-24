import Foundation
import Observation
import WatchtowerCore

/// State behind Settings → Profile → Instructions. Everything goes through
/// `watchtower instructions … --json`; the texts are not part of config.yaml,
/// so each field has its own Save button.
@MainActor
@Observable
final class InstructionsSettingsModel {
    private(set) var state: OwnerInstructionsState?
    var drafts: [InstructionField: String] = [:]
    private(set) var errors: [InstructionField: String] = [:]
    private(set) var loadError: String?
    private(set) var busy = false
    /// Said under the section when a reload had to drop an unsaved edit.
    private(set) var notice: String?

    @ObservationIgnored private var cli: WorkbenchCLI?

    init(cli: WorkbenchCLI?) { self.cli = cli }

    func replaceCLI(_ cli: WorkbenchCLI?) { self.cli = cli }

    /// The conversation an "Open chat" link opens; nil = the line has none, no link.
    static func openChatTarget(_ line: OwnerInstructionChatLine) -> Int64? { line.conversationID }

    func load() async {
        guard let cli else { loadError = "watchtower binary not found."; return }
        do {
            state = try await cli.instructions(workbenchID: nil)
            loadError = nil
        } catch {
            loadError = "Could not load instructions: \(error.localizedDescription)"
        }
    }

    /// A chat remembered a line (or undid one): re-read the saved texts. An
    /// unsaved edit of the chat text is dropped — Save would write it over the
    /// line that was just added — and the owner is told; the other fields are
    /// untouched by remember, so their drafts stay.
    func rememberRevisionChanged() async {
        let stale = OwnerInstructionsState.hasUnsavedEdit(draft: drafts[.chat], stored: state?.global.chat ?? "")
        await load()
        guard stale else { return }
        drafts[.chat] = nil
        notice = "A line was added from a chat, so your unsaved edit to the chat text was reset."
    }

    func save(_ field: InstructionField, body: String) async {
        guard let cli else { return }
        busy = true
        defer { busy = false }
        do {
            state = try await cli.setInstruction(field: field, workbenchID: nil, body: body)
            drafts[field] = nil
            errors[field] = nil
            notice = nil
        } catch {
            errors[field] = error.localizedDescription
        }
    }

    func decide(_ row: InstructionSuggestion, add: Bool) async {
        guard let cli else { return }
        busy = true
        defer { busy = false }
        do {
            state = try await cli.decideSuggestion(id: row.id, add: add)
            // An unsaved draft stays: only a field with no draft follows the new stored text.
            errors[row.field] = nil
        } catch {
            errors[row.field] = error.localizedDescription
        }
    }
}
