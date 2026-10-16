import Foundation
import Observation

/// The edit form's drafts, their saves and the confirmation sheet's
/// confirm (spec §3.3, §6.4, §12.2). Owned by `AppState`, so a save started
/// in the form finishes, and a draft is kept, when the form or the tab goes
/// away.
///
/// A save binds the confirmation to the bytes the owner saw: the text is
/// written to a private temp file, `validate --against` measures it, and the
/// same bytes are saved with `--confirm-hash` = that validation's
/// `approval_hash` and `--expect-content-hash` = the hash of the file the
/// draft was loaded from, so a recipe changed on disk since is refused, not
/// overwritten. No auto grant is kept unless the owner checked its box (AUTO-03).
@MainActor
@Observable
package final class AutomationEditorCenter {
    package struct EditDraft {
        package let form: AutomationFormModel
    }

    package enum SaveState: Equatable, Sendable {
        case validating
        /// The Save sheet is up with this plan.
        case review(AutomationSavePlan)
        case saving
        case done
        case failed(String)
    }

    package enum ConfirmState: Equatable, Sendable {
        case confirming
        /// The shown hash was stale; the detail was read again.
        case stale(String)
        case done
        case failed(String)
    }

    /// The draft key of the "New automation" sheet's **Form** tab: a recipe
    /// not saved yet has no automation id.
    nonisolated package static let newRecipeID: Int64 = 0

    nonisolated package static let changedOnDisk =
        "The recipe changed on disk since you opened it — reload it and review again."
    nonisolated package static let changedAgain = "The recipe changed again — review it once more."

    package private(set) var drafts: [Int64: EditDraft] = [:]
    package private(set) var saving: [Int64: SaveState] = [:]
    package private(set) var confirmations: [Int64: ConfirmState] = [:]
    /// Why opening the form failed, keyed by automation id.
    package private(set) var loadErrors: [Int64: String] = [:]
    /// Why the last Auto toggle failed, keyed by automation id.
    package private(set) var autoErrors: [Int64: String] = [:]

    @ObservationIgnored private let cli: AutomationsCLI
    @ObservationIgnored private let grants: @MainActor (Int64) async throws -> [AutomationToolGrant]
    @ObservationIgnored private let refresh: @MainActor (Int64) async -> Void
    @ObservationIgnored private let tempDirectory: URL
    /// The text `prepareSave` validated, which `commit` writes.
    @ObservationIgnored private var validatedTexts: [Int64: String] = [:]

    /// `grants` reads an automation's auto grants; `refresh` re-reads the list
    /// and the card's detail after a write.
    package init(
        cli: AutomationsCLI,
        grants: @escaping @MainActor (Int64) async throws -> [AutomationToolGrant],
        refresh: @escaping @MainActor (Int64) async -> Void,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.cli = cli
        self.grants = grants
        self.refresh = refresh
        self.tempDirectory = tempDirectory
    }

    /// What the edit form shows for an automation.
    package enum FormContent {
        case loading
        case editing(AutomationFormModel)
        case loadFailed(String)
        /// The draft is gone but the save's outcome is not done ("Saved, but
        /// auto could not be kept …"): shown until the form is closed.
        case finished(String)
    }

    package func formContent(_ id: Int64) -> FormContent {
        if let form = drafts[id]?.form { return .editing(form) }
        if let error = loadErrors[id] { return .loadFailed(error) }
        if case let .failed(message) = saving[id] { return .finished(message) }
        return .loading
    }

    // MARK: - Drafts

    /// Opens the form: loads the recipe with `show --json`. A draft with
    /// unsaved edits is kept as it is, never replaced by the file.
    package func beginEdit(_ id: Int64) async {
        if case .saving = saving[id] { return }
        if drafts[id]?.form.buffer.isDirty == true { return }
        saving[id] = nil
        do {
            let detail = try await cli.show(id)
            drafts[id] = EditDraft(form: AutomationFormModel(detail: detail))
            loadErrors[id] = nil
        } catch {
            loadErrors[id] = Self.message(for: error)
        }
    }

    /// The **Form** tab of "New automation": an empty personal recipe that
    /// saves into `automationsDir` (`<workspace>/automations`) under a slug
    /// made from its name. A draft already open is kept.
    package func beginNew(automationsDir: String) {
        let id = Self.newRecipeID
        if drafts[id] != nil || saving[id] == .saving { return }
        saving[id] = nil
        loadErrors[id] = nil
        drafts[id] = EditDraft(form: AutomationFormModel(detail: AutomationDetail(newRecipeIn: automationsDir)))
    }

    /// Drops the draft and anything the form left in flight.
    package func discard(_ id: Int64) {
        guard saving[id] != .saving else { return }
        drafts[id] = nil
        saving[id] = nil
        validatedTexts[id] = nil
        loadErrors[id] = nil
    }

    // MARK: - Save

    /// The form's **Save and confirm**: validates the draft, then saves at
    /// once, or puts the Save sheet up when the plan needs it.
    package func save(_ id: Int64) async {
        guard let draft = drafts[id], saving[id] != .saving, saving[id] != .validating else { return }
        // The last keystroke may still sit in the page's debounce: the bytes
        // validated and saved are the ones on screen.
        await draft.form.buffer.flush()
        guard let plan = await prepareSave(id, text: draft.form.renderedText()) else { return }
        if plan.needsSheet {
            saving[id] = .review(plan)
        } else {
            await commit(id, plan: plan)
        }
    }

    /// Writes `text` to a private temp file and runs `validate --against`;
    /// nil (with `saving[id]` failed) when it does not validate.
    package func prepareSave(_ id: Int64, text: String) async -> AutomationSavePlan? {
        guard let draft = drafts[id] else { return nil }
        saving[id] = .validating
        do {
            let isNew = id == Self.newRecipeID
            let validated = try await withTempRecipe(text, slug: draft.form.detail.slug) { file in
                try await cli.validate(file: file, against: isNew ? nil : id)
            }
            guard validated.ok else {
                saving[id] = .failed("The recipe has errors:\n" + validated.errors.joined(separator: "\n"))
                return nil
            }
            let plan = AutomationSavePlan.make(validated: validated, current: draft.form.detail,
                                               grants: isNew ? [] : try await grants(id))
            validatedTexts[id] = text
            saving[id] = nil
            return plan
        } catch {
            saving[id] = .failed(Self.message(for: error))
            return nil
        }
    }

    /// The Save sheet was cancelled: nothing is written.
    package func cancelReview(_ id: Int64) {
        guard case .review = saving[id] else { return }
        saving[id] = nil
        validatedTexts[id] = nil
    }

    /// Saves the validated text, confirming `plan.validated.approvalHash`,
    /// then keeps auto for exactly the tools in `plan.keepAuto`.
    package func commit(_ id: Int64, plan: AutomationSavePlan) async {
        guard let draft = drafts[id], let text = validatedTexts[id] else { return }
        saving[id] = .saving
        // A new recipe is saved at a slug made from its name, and only where
        // no file exists yet (an empty expected hash).
        let isNew = id == Self.newRecipeID
        let slug = isNew ? Self.slug(forName: draft.form.fields.name) : draft.form.detail.slug
        let path = isNew ? (draft.form.detail.path as NSString).appendingPathComponent("\(slug).md")
                         : draft.form.detail.path
        let saved: AutomationsCLI.SaveResult
        do {
            saved = try await withTempRecipe(text, slug: slug) { file in
                try await cli.save(file: file, path: path,
                                   confirmHash: plan.validated.approvalHash,
                                   expectContentHash: isNew ? "" : draft.form.buffer.baseContentHash)
            }
        } catch {
            saving[id] = .failed(Self.saveMessage(for: error))
            return
        }
        validatedTexts[id] = nil
        var autoFailures: [String] = []
        for tool in plan.keepAuto.sorted() {
            do {
                try await cli.setAuto(saved.automationID, tool: tool, on: true, hash: saved.approvalHash)
            } catch {
                autoFailures.append("\(tool): \(Self.message(for: error))")
            }
        }
        drafts[id] = nil
        saving[id] = autoFailures.isEmpty
            ? .done
            : .failed("Saved, but auto could not be kept for " + autoFailures.joined(separator: "; "))
        await refresh(saved.automationID)
    }

    // MARK: - Auto

    /// The form's **Auto** toggle for one write tool: `auto … on --hash
    /// <the loaded approval hash>` or `off`. An edit not saved yet is not
    /// what the grant binds: the hash is the recipe's as it is indexed.
    package func setAuto(_ id: Int64, tool: String, on: Bool) async {
        guard let detail = drafts[id]?.form.detail else { return }
        do {
            try await cli.setAuto(id, tool: tool, on: on, hash: on ? detail.approvalHash : nil)
            autoErrors[id] = nil
        } catch {
            autoErrors[id] = Self.message(for: error)
        }
        await refresh(id)
    }

    // MARK: - Confirm

    /// The confirmation sheet's **Confirm** (or **Confirm and enable**):
    /// `confirm --hash <shown hash>`. A stale hash re-reads the detail and
    /// asks the owner to review again.
    package func confirmForeign(_ id: Int64, shownHash: String, enable: Bool = false) async {
        guard confirmations[id] != .confirming else { return }
        confirmations[id] = .confirming
        do {
            try await cli.confirm(id, hash: shownHash)
        } catch {
            let message = Self.message(for: error)
            confirmations[id] = message.contains("approval hash does not match") ? .stale(Self.changedAgain)
                                                                               : .failed(message)
            await refresh(id)
            return
        }
        if enable {
            do {
                try await cli.setEnabled(id, true)
            } catch {
                confirmations[id] = .failed("Confirmed, but not enabled: " + Self.message(for: error))
                await refresh(id)
                return
            }
        }
        confirmations[id] = .done
        await refresh(id)
    }

    /// The sheet was closed: its outcome is no longer shown.
    package func closeConfirmation(_ id: Int64) {
        guard confirmations[id] != .confirming else { return }
        confirmations[id] = nil
    }

    // MARK: - Helpers

    /// A recipe slug (`^[a-z0-9][a-z0-9-]{0,63}$`) from a name: lowercase
    /// ASCII letters and digits, every other run as one hyphen.
    nonisolated package static func slug(forName name: String) -> String {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out += "-"
            }
        }
        let trimmed = String(out.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "automation" : trimmed
    }

    /// Runs `body` on `text` written to `<private dir>/<slug>.md` (dir 0700,
    /// file 0600); the directory is removed on every path.
    private func withTempRecipe<T>(_ text: String, slug: String, _ body: (URL) async throws -> T) async throws -> T {
        let fm = FileManager.default
        let dir = tempDirectory.appendingPathComponent("watchtower-automation-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("\(slug).md")
        guard fm.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        return try await body(file)
    }

    private static func saveMessage(for error: Error) -> String {
        let message = message(for: error)
        return message.contains("changed on disk since you opened it") ? changedOnDisk : message
    }

    private static func message(for error: Error) -> String {
        if case let CLIRunnerError.nonZeroExit(code, stderr) = error {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "watchtower exited with code \(code)" : text
        }
        return error.localizedDescription
    }
}

extension AutomationDetail {
    /// The **Form** tab's starting point: a personal manual recipe with a
    /// description and a script to replace. `path` holds the directory the
    /// recipe will be saved in; the file name comes from the name at save.
    package init(newRecipeIn automationsDir: String) {
        let fields = RecipeFrontmatter(name: "New automation", trigger: .manual)
        id = AutomationEditorCenter.newRecipeID
        slug = "new-automation"
        scope = "personal"
        projectID = 0
        path = automationsDir
        name = fields.name
        description = "What it does, in a sentence."
        script = "return \"done\""
        recipeText = RecipeFrontmatter.render(fields) + "\(description)\n\n```js\n\(script)\n```\n"
        triggerKind = "manual"
        triggerSpec = #"{"manual":true}"#
        permissions = []
        outputs = []
        budgetTokens = fields.budgetTokens
        budgetMinutes = fields.budgetMinutes
        concurrency = fields.concurrency
        missedPolicy = fields.missed
        pauseTimeoutHours = fields.pauseTimeoutHours
        enabled = false
        runnable = false
        needsConfirmation = true
        parseError = ""
        contentHash = ""
        approvalHash = ""
        confirmedHash = ""
        widening = []
        changes = []
        changesKnown = false
        changedBy = ""
        changedAt = nil
        autoTools = []
    }

    package var isNewRecipe: Bool { id == AutomationEditorCenter.newRecipeID }
}
