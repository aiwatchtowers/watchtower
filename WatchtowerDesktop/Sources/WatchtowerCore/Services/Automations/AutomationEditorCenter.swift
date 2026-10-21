import Foundation
import Observation
import os

/// The editor panel's drafts, their in-place checks and saves, and the
/// confirm of unchanged bytes (spec §3.3, §6.4, §12.2). Owned by `AppState`,
/// so a save started in the panel finishes, and a draft is kept, when the
/// panel or the tab goes away.
///
/// Drafts are keyed by `Int64`: a saved automation by its id, a new draft by
/// `newDraftKey(conversationID:)` (negative). Every text change is checked
/// `checkDelay` after the bytes stop changing (`textChanged` → `check`): the
/// text is written to a private temp file and `validate` measures it; the
/// panel shows the resulting plan's hashed fields. The owner's press
/// (`commit`) saves exactly those bytes with `--confirm-hash` = that
/// validation's `approval_hash` and `--expect-content-hash` = the hash of the
/// file the draft was loaded from (AUTO-06), so a recipe changed on disk since
/// is refused, not overwritten; bytes changed since the check are checked
/// again, never saved. No auto grant is kept unless the owner checked its box
/// (AUTO-03).
@MainActor
@Observable
package final class AutomationEditorCenter {
    package struct EditDraft {
        package let form: AutomationFormModel
    }

    package enum SaveState: Equatable, Sendable {
        case validating
        /// The draft was checked: the panel shows this plan (the legacy
        /// form's Save sheet is up with it).
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

    /// Why a text sits in `keptAside`.
    package enum AsideReason: Equatable, Sendable {
        /// **Reload** brought in the file as it is now.
        case reloadedFromDisk
        /// The assistant's draft replaced the owner's edits.
        case assistantReplaced
    }

    /// The draft key of the "New automation" sheet's **Form** tab: a recipe
    /// not saved yet has no automation id.
    nonisolated package static let newRecipeID: Int64 = 0

    /// The draft key of a new automation drafted in chat `conversationID`.
    nonisolated package static func newDraftKey(conversationID: Int64) -> Int64 { -conversationID }

    /// Whether `key` is a new draft's (`newDraftKey`).
    nonisolated package static func isNewDraft(_ key: Int64) -> Bool { key < 0 }

    nonisolated package static let asideAssistantReplaced = "The assistant's draft replaced your edits."
    nonisolated package static func notTurnedOn(_ message: String) -> String {
        "Saved and confirmed, but not turned on: \(message)"
    }

    nonisolated package static let changedOnDisk =
        "The recipe changed on disk since you opened it — reload it and review again."
    nonisolated package static func nameTaken(_ slug: String) -> String {
        "A recipe named \(slug).md already exists — pick another name."
    }
    nonisolated package static let changedAgain = "The recipe changed again — review it once more."

    package private(set) var drafts: [Int64: EditDraft] = [:]
    package private(set) var saving: [Int64: SaveState] = [:]
    package private(set) var confirmations: [Int64: ConfirmState] = [:]
    /// Why opening the form failed, keyed by automation id.
    package private(set) var loadErrors: [Int64: String] = [:]
    /// Why the last Auto toggle failed, keyed by automation id.
    package private(set) var autoErrors: [Int64: String] = [:]
    /// The text the owner had in the form when they reloaded a recipe that
    /// changed on disk (`reloadFromDisk`), so a reload never loses it; kept
    /// until the draft is discarded or saved.
    package private(set) var keptAside: [Int64: String] = [:]
    /// Why each `keptAside` text was put there.
    package private(set) var asideReason: [Int64: AsideReason] = [:]
    /// The automation a draft's save wrote, by draft key: a retry after
    /// "not turned on" only turns it on.
    package private(set) var savedIDs: [Int64: Int64] = [:]

    @ObservationIgnored private let cli: AutomationsCLI
    @ObservationIgnored private let grants: @MainActor (Int64) async throws -> [AutomationToolGrant]
    @ObservationIgnored private let refresh: @MainActor (Int64) async -> Void
    @ObservationIgnored private let tempDirectory: URL
    @ObservationIgnored private let draftCacheDir: URL?
    @ObservationIgnored private let checkDelay: Duration
    @ObservationIgnored private let sleep: (Duration) async -> Void
    /// The text the last check validated, which `commit` writes.
    @ObservationIgnored private var validatedTexts: [Int64: String] = [:]
    /// The pending debounced check, per key.
    @ObservationIgnored private var checkTasks: [Int64: Task<Void, Never>] = [:]
    /// Bumped by every check: only the newest check's result is shown.
    @ObservationIgnored private var checkGenerations: [Int64: Int] = [:]
    /// The newest chat draft text already in (or deliberately kept out of) the buffer.
    @ObservationIgnored private var lastAdopted: [Int64: String] = [:]
    /// The buffer text right after the last load or adoption: a buffer that
    /// differs holds the owner's edits.
    @ObservationIgnored private var adoptBase: [Int64: String] = [:]
    /// A new draft's file name from the chat (`^[a-z0-9][a-z0-9-]{0,63}$`).
    @ObservationIgnored private var slugHints: [Int64: String] = [:]

    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "automation-editor")

    /// `grants` reads an automation's auto grants; `refresh` re-reads the list
    /// and the card's detail after a write. `draftCacheDir` is
    /// `<workspace>/automation-drafts`, whose `<conversation id>.jsonl` a new
    /// draft's save removes. `sleep` is the debounce's wait (a test seam).
    package init(
        cli: AutomationsCLI,
        grants: @escaping @MainActor (Int64) async throws -> [AutomationToolGrant],
        refresh: @escaping @MainActor (Int64) async -> Void,
        draftCacheDir: URL? = nil,
        tempDirectory: URL = FileManager.default.temporaryDirectory,
        checkDelay: Duration = .milliseconds(500),
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.cli = cli
        self.grants = grants
        self.refresh = refresh
        self.draftCacheDir = draftCacheDir
        self.tempDirectory = tempDirectory
        self.checkDelay = checkDelay
        self.sleep = sleep
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
        _ = await load(id)
    }

    /// Opens the editor panel on a saved automation: loads it like
    /// `beginEdit(_:)`, records the chat's newest draft text as already
    /// adopted (opening never pulls in an old cached draft), then checks it.
    package func beginEdit(_ id: Int64, chatNewestText: String?) async {
        if let chatNewestText { lastAdopted[id] = chatNewestText }
        guard await load(id) else { return }
        scheduleCheck(id)
    }

    /// Whether a draft is open after the load (a loaded or kept one).
    private func load(_ id: Int64) async -> Bool {
        if case .saving = saving[id] { return false }
        if drafts[id]?.form.buffer.isDirty == true { return true }
        saving[id] = nil
        do {
            let detail = try await cli.show(id)
            drafts[id] = EditDraft(form: AutomationFormModel(detail: detail))
            adoptBase[id] = detail.recipeText
            loadErrors[id] = nil
            return true
        } catch {
            loadErrors[id] = Self.message(for: error)
            return false
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

    /// A new draft (`newDraftKey`) in `scope`, saved into `recipeDir`; the
    /// buffer starts from `startText` when given (a template's or the chat's
    /// text). A draft already open is kept.
    package func beginNew(key: Int64, scope: AutomationScopeChoice, recipeDir: String, startText: String?) {
        if drafts[key] != nil || saving[key] == .saving { return }
        saving[key] = nil
        loadErrors[key] = nil
        let form = AutomationFormModel(detail: AutomationDetail(newRecipeIn: recipeDir, scope: scope))
        if let startText { form.buffer.replace(text: startText) }
        drafts[key] = EditDraft(form: form)
        adoptBase[key] = form.renderedText()
        scheduleCheck(key)
    }

    /// The chat's newest draft text: replaces the buffer unless it is the
    /// text already adopted. Owner edits made since the last adoption are
    /// kept aside (`keptAside`, `.assistantReplaced`) for **Restore**.
    package func adoptChatDraft(_ key: Int64, text: String, slug: String?) {
        guard let form = drafts[key]?.form, saving[key] != .saving, lastAdopted[key] != text else { return }
        let current = form.renderedText()
        if current != (adoptBase[key] ?? form.detail.recipeText), current != text {
            keptAside[key] = current
            asideReason[key] = .assistantReplaced
        }
        form.buffer.replace(text: text)
        lastAdopted[key] = text
        adoptBase[key] = text
        if let slug, slug.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil {
            slugHints[key] = slug
        }
        scheduleCheck(key)
    }

    /// **Restore**: the text kept aside goes back into the buffer.
    package func restoreAside(_ key: Int64) {
        guard let form = drafts[key]?.form, let aside = keptAside[key], saving[key] != .saving else { return }
        form.buffer.replace(text: aside)
        keptAside[key] = nil
        asideReason[key] = nil
        scheduleCheck(key)
    }

    /// Drops the draft and anything the form left in flight.
    package func discard(_ id: Int64) {
        guard saving[id] != .saving else { return }
        checkTasks[id]?.cancel()
        checkTasks[id] = nil
        drafts[id] = nil
        saving[id] = nil
        validatedTexts[id] = nil
        loadErrors[id] = nil
        keptAside[id] = nil
        asideReason[id] = nil
        lastAdopted[id] = nil
        adoptBase[id] = nil
        slugHints[id] = nil
        savedIDs[id] = nil
    }

    /// **Reload** after a save was refused because the recipe changed on
    /// disk: the form reloads the file as it is now, and the owner's text is
    /// kept aside (`keptAside`) to copy back — `beginEdit` alone never
    /// replaces a dirty draft, so without this only Discard would help.
    package func reloadFromDisk(_ id: Int64) async {
        guard id != Self.newRecipeID, let draft = drafts[id],
              saving[id] != .saving, saving[id] != .validating else { return }
        await draft.form.buffer.flush()
        let aside = draft.form.renderedText()
        do {
            let detail = try await cli.show(id)
            keptAside[id] = aside
            asideReason[id] = .reloadedFromDisk
            drafts[id] = EditDraft(form: AutomationFormModel(detail: detail))
            adoptBase[id] = detail.recipeText
            saving[id] = nil
            validatedTexts[id] = nil
            loadErrors[id] = nil
        } catch {
            saving[id] = .failed(Self.message(for: error))
        }
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
            let (validated, plan) = try await measure(id, draft: draft, text: text)
            guard let plan else {
                saving[id] = .failed(Self.recipeErrors(validated))
                return nil
            }
            validatedTexts[id] = text
            saving[id] = nil
            return plan
        } catch {
            saving[id] = .failed(Self.message(for: error))
            return nil
        }
    }

    /// `validate` of `text` (`--against` for a saved automation,
    /// `--workbench` for a new workbench draft) and, when it validates, the
    /// plan the panel shows.
    private func measure(_ key: Int64, draft: EditDraft, text: String) async throws
        -> (AutomationsCLI.ValidateResult, AutomationSavePlan?) {
        let detail = draft.form.detail
        let isNew = Self.isNew(key)
        let validated = try await withTempRecipe(text, slug: detail.slug) { file in
            try await cli.validate(file: file, against: isNew ? nil : key,
                                   workbench: isNew && detail.scope == "workbench" ? detail.projectID : nil)
        }
        guard validated.ok else { return (validated, nil) }
        let plan = AutomationSavePlan.make(validated: validated, current: detail,
                                           grants: isNew ? [] : try await grants(key))
        return (validated, plan)
    }

    // MARK: - Check in place

    /// The view saw the draft's text change: the check runs `checkDelay`
    /// after the last change.
    package func textChanged(_ key: Int64) {
        scheduleCheck(key)
    }

    private func scheduleCheck(_ key: Int64) {
        checkTasks[key]?.cancel()
        let delay = checkDelay
        let sleep = sleep
        checkTasks[key] = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            // Not cancelled, so still the pending task: a check started
            // directly from here on must not cancel the running one.
            checkTasks[key] = nil
            await check(key)
        }
    }

    /// Validates the draft as it is now (the page's pending keystroke
    /// flushed first): `.validating`, then `.review(plan)` or `.failed`. A
    /// result for text changed since, or overtaken by a newer check, is
    /// dropped. An unreadable recipe's banner (`currentParseError`) follows
    /// the same result.
    package func check(_ key: Int64) async {
        guard let draft = drafts[key], saving[key] != .saving else { return }
        // A check started directly overtakes the pending debounced one.
        checkTasks[key]?.cancel()
        checkTasks[key] = nil
        await draft.form.buffer.flush()
        let generation = (checkGenerations[key] ?? 0) + 1
        checkGenerations[key] = generation
        let text = draft.form.renderedText()
        validatedTexts[key] = nil
        saving[key] = .validating
        let outcome: Result<(AutomationsCLI.ValidateResult, AutomationSavePlan?), Error>
        do {
            outcome = .success(try await measure(key, draft: draft, text: text))
        } catch {
            outcome = .failure(error)
        }
        guard checkGenerations[key] == generation, drafts[key]?.form === draft.form,
              saving[key] == .validating else { return }
        guard draft.form.renderedText() == text else {
            // Typed while the check ran and nothing newer is scheduled: check again.
            if checkTasks[key] == nil { scheduleCheck(key) }
            return
        }
        switch outcome {
        case let .success((validated, plan)):
            if draft.form.recipeUnparsed {
                draft.form.currentParseError = validated.ok ? "" : validated.errors.joined(separator: "\n")
            }
            if let plan {
                validatedTexts[key] = text
                saving[key] = .review(plan)
            } else {
                saving[key] = .failed(Self.recipeErrors(validated))
            }
        case let .failure(error):
            saving[key] = .failed(Self.message(for: error))
        }
    }

    /// Whether the panel's save buttons are on: the draft was checked, it
    /// validates with every hashed field shown (AUTO-06), and the bytes on
    /// screen are the bytes checked.
    package func canSave(_ key: Int64) -> Bool {
        guard case let .review(plan) = saving[key], plan.validated.showsAllFields,
              let form = drafts[key]?.form else { return false }
        return validatedTexts[key] == form.renderedText()
    }

    /// A recipe loaded with a parse error (#582): re-validates the text as
    /// it is now, so the form's banner follows the owner's fix in Monaco.
    /// The loaded text needs no call; a failed call leaves the banner as it
    /// was, and a result for text changed since is dropped.
    package func recheckParse(_ id: Int64) async {
        guard let form = drafts[id]?.form, form.recipeUnparsed, saving[id] == nil else { return }
        let text = form.renderedText()
        guard text != form.detail.recipeText else {
            form.currentParseError = form.detail.parseError
            return
        }
        guard let validated = try? await withTempRecipe(text, slug: form.detail.slug, { file in
            try await cli.validate(file: file, against: id)
        }), drafts[id]?.form === form, form.renderedText() == text else { return }
        form.currentParseError = validated.ok ? "" : validated.errors.joined(separator: "\n")
    }

    /// The panel's **Save and Turn On** / **Save and Confirm** (`turnOn`) or
    /// **Save Turned Off**: saves the checked bytes, confirming
    /// `plan.validated.approvalHash` (AUTO-06). Bytes changed since the check
    /// (the page's pending keystroke included) are checked again instead of
    /// saved. An enabled automation saved turned off is disabled first; a
    /// turned-on save enables after the confirmed save. A retry after "not
    /// turned on" only enables.
    package func commit(_ key: Int64, plan: AutomationSavePlan, turnOn: Bool) async {
        guard saving[key] != .saving, saving[key] != .validating else { return }
        guard let draft = drafts[key] else {
            if case .failed = saving[key], turnOn, let savedID = savedIDs[key] { await enableAfterSave(key, savedID) }
            return
        }
        await draft.form.buffer.flush()
        let text = draft.form.renderedText()
        guard case let .review(checked) = saving[key], checked.validated.approvalHash == plan.validated.approvalHash,
              plan.validated.showsAllFields, validatedTexts[key] == text else {
            await check(key)
            return
        }
        let detail = draft.form.detail
        let isNew = Self.isNew(key)
        let disableFirst = !isNew && detail.enabled && !turnOn
        if disableFirst {
            saving[key] = .saving
            do {
                try await cli.setEnabled(key, false)
            } catch {
                saving[key] = .failed(Self.message(for: error))
                await refresh(key)
                return
            }
        }
        guard let saved = await performSave(key, draft: draft, text: text, plan: plan) else {
            if disableFirst { await refresh(key) }
            return
        }
        savedIDs[key] = saved.automationID
        if Self.isNewDraft(key) { removeDraftCache(key) }
        if turnOn, isNew || !detail.enabled {
            do {
                try await cli.setEnabled(saved.automationID, true)
            } catch {
                let notOn = Self.notTurnedOn(Self.message(for: error))
                if case let .failed(autoMessage) = saving[key] {
                    saving[key] = .failed(notOn + "\n" + autoMessage)
                } else {
                    saving[key] = .failed(notOn)
                }
            }
        }
        await refresh(saved.automationID)
    }

    private func enableAfterSave(_ key: Int64, _ id: Int64) async {
        saving[key] = .saving
        do {
            try await cli.setEnabled(id, true)
            saving[key] = .done
        } catch {
            saving[key] = .failed(Self.notTurnedOn(Self.message(for: error)))
        }
        await refresh(id)
    }

    /// The panel's **Confirm** family for unchanged bytes: confirms the hash
    /// the panel showed, then turns it on when `turnOn`. A draft with edits
    /// is checked, not confirmed.
    package func confirmShown(_ id: Int64, plan: AutomationSavePlan, turnOn: Bool) async {
        // Only a screen that showed every hashed field confirms (AUTO-06).
        guard plan.validated.showsAllFields else {
            saving[id] = .failed(AutomationDraftFooter.cantShowAllHint)
            return
        }
        if let form = drafts[id]?.form {
            await form.buffer.flush()
            guard !form.buffer.isDirty else {
                await check(id)
                return
            }
        }
        await confirmForeign(id, shownHash: plan.validated.approvalHash, enable: turnOn)
    }

    private func removeDraftCache(_ key: Int64) {
        guard let draftCacheDir else { return }
        let file = draftCacheDir.appendingPathComponent("\(-key).jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            let reason = error.localizedDescription
            Self.log.error("could not remove the draft cache \(file.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
        }
    }

    /// The Save sheet was cancelled: nothing is written.
    package func cancelReview(_ id: Int64) {
        guard case .review = saving[id] else { return }
        saving[id] = nil
        validatedTexts[id] = nil
    }

    /// The legacy form's Save sheet: saves the validated text, confirming
    /// `plan.validated.approvalHash`, then keeps auto for exactly the tools in
    /// `plan.keepAuto`.
    package func commit(_ id: Int64, plan: AutomationSavePlan) async {
        guard let draft = drafts[id], let text = validatedTexts[id] else { return }
        guard let saved = await performSave(id, draft: draft, text: text, plan: plan) else { return }
        await refresh(saved.automationID)
    }

    /// Saves `text` with `--confirm-hash plan.validated.approvalHash`, then
    /// keeps auto for exactly `plan.keepAuto`; nil (with `saving` failed)
    /// when the save is refused. The draft is gone after a save.
    private func performSave(_ key: Int64, draft: EditDraft, text: String, plan: AutomationSavePlan) async
        -> AutomationsCLI.SaveResult? {
        saving[key] = .saving
        // A new recipe is saved at a slug made from its name, and only where
        // no file exists yet (an empty expected hash).
        let isNew = Self.isNew(key)
        // A new draft's text may come from the chat or a template, whose
        // name the form's fields do not hold: the validated name is the text's.
        let name = Self.isNewDraft(key) && !plan.validated.name.isEmpty ? plan.validated.name : draft.form.fields.name
        let slug = isNew ? slugHints[key] ?? Self.slug(forName: name) : draft.form.detail.slug
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
            let message = Self.saveMessage(for: error)
            // A new recipe was never opened: a file at its slug is a name clash.
            saving[key] = .failed(isNew && message == Self.changedOnDisk ? Self.nameTaken(slug) : message)
            return nil
        }
        validatedTexts[key] = nil
        keptAside[key] = nil
        asideReason[key] = nil
        var autoFailures: [String] = []
        for tool in plan.keepAuto.sorted() {
            do {
                try await cli.setAuto(saved.automationID, tool: tool, on: true, hash: saved.approvalHash)
            } catch {
                autoFailures.append("\(tool): \(Self.message(for: error))")
            }
        }
        checkTasks[key]?.cancel()
        checkTasks[key] = nil
        drafts[key] = nil
        saving[key] = autoFailures.isEmpty
            ? .done
            : .failed("Saved, but auto could not be kept for " + autoFailures.joined(separator: "; "))
        return saved
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

    /// A saved automation's key, or a new recipe's (the legacy form's or a
    /// new draft's).
    nonisolated private static func isNew(_ key: Int64) -> Bool {
        key == newRecipeID || isNewDraft(key)
    }

    private static func recipeErrors(_ validated: AutomationsCLI.ValidateResult) -> String {
        "The recipe has errors:\n" + validated.errors.joined(separator: "\n")
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
    /// A new recipe's starting point: a manual recipe in `scope` with a
    /// description and a script to replace. `path` holds the directory the
    /// recipe will be saved in; the file name comes from the name at save.
    package init(newRecipeIn automationsDir: String, scope choice: AutomationScopeChoice = .personal) {
        let fields = RecipeFrontmatter(name: "New automation", trigger: .manual)
        id = AutomationEditorCenter.newRecipeID
        slug = "new-automation"
        scope = choice.workbenchID == nil ? "personal" : "workbench"
        projectID = choice.workbenchID ?? 0
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
        llmAutoWrites = []
        feedsSourcesToLLM = false
    }

    package var isNewRecipe: Bool { id == AutomationEditorCenter.newRecipeID }
}
