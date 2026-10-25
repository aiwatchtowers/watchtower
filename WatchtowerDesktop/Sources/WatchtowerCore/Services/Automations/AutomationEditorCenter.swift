import Foundation
import GRDB
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
    package enum SaveState: Equatable, Sendable {
        case validating
        /// The draft was checked: the panel shows this plan.
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

    /// The draft key of a new automation drafted in chat `conversationID`.
    nonisolated package static func newDraftKey(conversationID: Int64) -> Int64 { -conversationID }

    /// Whether `key` is a new draft's (`newDraftKey`).
    nonisolated package static func isNewDraft(_ key: Int64) -> Bool { key < 0 }

    nonisolated package static let asideAssistantReplaced = "The assistant's draft replaced your edits."
    nonisolated package static func notTurnedOn(_ message: String) -> String {
        "Saved and confirmed, but not turned on: \(message)"
    }

    nonisolated package static func confirmedNotEnabled(_ message: String) -> String {
        "Confirmed, but not enabled: \(message)"
    }

    nonisolated package static let changedOnDisk =
        "The recipe changed on disk since you opened it — reload it and review again."
    nonisolated package static func nameTaken(_ slug: String) -> String {
        "A recipe named \(slug).md already exists — pick another name."
    }
    nonisolated package static let changedAgain = "The recipe changed again — review it once more."

    package private(set) var drafts: [Int64: AutomationFormModel] = [:]
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
    /// The newest check's `validate` result, valid or not, by draft key: the
    /// draft column shows it (its errors too) while it is of the bytes on
    /// screen (its `content_hash`).
    package private(set) var lastChecked: [Int64: AutomationsCLI.ValidateResult] = [:]
    /// The "Keep auto" boxes the owner checked, by draft key (AUTO-03):
    /// empty by default, and emptied by every check that measures a new
    /// approval hash, so a box checked under one hash is never carried to
    /// another. Only a paused grant of the shown plan can be checked.
    package private(set) var keepAuto: [Int64: Set<String>] = [:]
    /// Drafts whose save or confirm landed but whose turn-on failed: the
    /// panel offers **Turn On** (`retryTurnOn`).
    package private(set) var turnOnPending: Set<Int64> = []

    /// The approval hash `keepAuto` was checked under, by draft key.
    @ObservationIgnored private var keepAutoHash: [Int64: String] = [:]
    @ObservationIgnored private let cli: AutomationsCLI
    @ObservationIgnored private let grants: @MainActor (Int64) async throws -> [AutomationToolGrant]
    @ObservationIgnored private let refresh: @MainActor (Int64) async -> Void
    @ObservationIgnored private let draftCache: (any DatabaseWriter)?
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
    /// Drafts whose chat composer was prefilled already (`claimComposerPrefill`).
    @ObservationIgnored private var prefilled: Set<Int64> = []
    /// The `beginEdit` start text each draft adopted already.
    @ObservationIgnored private var startAdopted: [Int64: String] = [:]

    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "automation-editor")

    /// `grants` reads an automation's auto grants; `refresh` re-reads the list
    /// and the card's detail after a write. `draftCache` is the database
    /// whose `automation_draft_cache` rows a new draft's save removes (the
    /// view model removes them in the app). `sleep` is the debounce's wait
    /// (a test seam).
    package init(
        cli: AutomationsCLI,
        grants: @escaping @MainActor (Int64) async throws -> [AutomationToolGrant],
        refresh: @escaping @MainActor (Int64) async -> Void,
        draftCache: (any DatabaseWriter)? = nil,
        checkDelay: Duration = .milliseconds(500),
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.cli = cli
        self.grants = grants
        self.refresh = refresh
        self.draftCache = draftCache
        self.checkDelay = checkDelay
        self.sleep = sleep
    }

    // MARK: - Drafts

    /// Opens the editor panel on a saved automation: loads the recipe with
    /// `show --json` (a draft with unsaved edits is kept as it is, never
    /// replaced by the file), records the chat's newest draft text as already
    /// adopted (opening never pulls in an old cached draft), then checks it.
    /// A `startText` (an Inbox proposal's recipe) is then adopted over the
    /// loaded text, as a chat draft is: edits in a kept draft go aside. It
    /// is adopted once per draft: the panel opening again on the same text
    /// keeps the owner's edits.
    package func beginEdit(_ id: Int64, chatNewestText: String?, startText: String? = nil) async {
        if let chatNewestText { lastAdopted[id] = chatNewestText }
        guard await load(id) else { return }
        guard let startText, startAdopted[id] != startText else {
            scheduleCheck(id)
            return
        }
        startAdopted[id] = startText
        // Adopted even when the chat's newest draft is this same text.
        lastAdopted[id] = nil
        adoptChatDraft(id, text: startText, slug: nil)
    }

    /// Whether a draft is open after the load (a loaded or kept one).
    private func load(_ id: Int64) async -> Bool {
        if case .saving = saving[id] { return false }
        if drafts[id]?.buffer.isDirty == true { return true }
        saving[id] = nil
        do {
            let detail = try await cli.show(id)
            drafts[id] = AutomationFormModel(detail: detail)
            adoptBase[id] = detail.recipeText
            loadErrors[id] = nil
            return true
        } catch {
            loadErrors[id] = Self.message(for: error)
            return false
        }
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
        drafts[key] = form
        adoptBase[key] = form.renderedText()
        scheduleCheck(key)
    }

    /// The chat's newest draft text: replaces the buffer unless it is the
    /// text already adopted. Owner edits made since the last adoption are
    /// kept aside (`keptAside`, `.assistantReplaced`) for **Restore**, unless
    /// a **Reload** aside is there: the text from before the reload stays.
    package func adoptChatDraft(_ key: Int64, text: String, slug: String?) {
        guard let form = drafts[key], saving[key] != .saving, lastAdopted[key] != text else { return }
        let current = form.renderedText()
        if current != (adoptBase[key] ?? form.detail.recipeText), current != text,
           asideReason[key] != .reloadedFromDisk {
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
        guard let form = drafts[key], let aside = keptAside[key], saving[key] != .saving else { return }
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
        lastChecked[id] = nil
        turnOnPending.remove(id)
        prefilled.remove(id)
        startAdopted[id] = nil
        keepAuto[id] = nil
        keepAutoHash[id] = nil
    }

    /// The new drafts open here, by conversation id, with the name the
    /// newest check read (empty before one): the list shows each as a draft
    /// row, also when its chat never drafted and no cache file exists.
    package var openNewDraftNames: [Int64: String] {
        var names: [Int64: String] = [:]
        for key in drafts.keys where Self.isNewDraft(key) {
            names[-key] = lastChecked[key]?.name ?? ""
        }
        return names
    }

    /// A "Keep auto" box: checks or unchecks `tool`, a grant the shown plan pauses.
    package func setKeepAuto(_ key: Int64, tool: String, on: Bool) {
        guard case let .review(plan) = saving[key], plan.pausedGrants.contains(tool) else { return }
        var kept = keepAuto[key] ?? []
        if on { kept.insert(tool) } else { kept.remove(tool) }
        keepAuto[key] = kept
    }

    /// True once per draft: the New flow's text goes into its chat's
    /// composer the first time the panel opens it, never again.
    package func claimComposerPrefill(_ key: Int64) -> Bool {
        prefilled.insert(key).inserted
    }

    /// **Reload** after a save was refused because the recipe changed on
    /// disk: the form reloads the file as it is now, and the owner's text is
    /// kept aside (`keptAside`) to copy back — `beginEdit` alone never
    /// replaces a dirty draft, so without this only Discard would help.
    package func reloadFromDisk(_ id: Int64) async {
        guard !Self.isNewDraft(id), let draft = drafts[id],
              saving[id] != .saving, saving[id] != .validating else { return }
        await draft.buffer.flush()
        let aside = draft.renderedText()
        do {
            let detail = try await cli.show(id)
            keptAside[id] = aside
            asideReason[id] = .reloadedFromDisk
            drafts[id] = AutomationFormModel(detail: detail)
            adoptBase[id] = detail.recipeText
            saving[id] = nil
            validatedTexts[id] = nil
            loadErrors[id] = nil
            // The reloaded text may equal the old one: nothing else would check it.
            scheduleCheck(id)
        } catch {
            saving[id] = .failed(Self.message(for: error))
        }
    }

    // MARK: - Save

    /// `validate` of `text` (`--against` for a saved automation,
    /// `--workbench` for a new workbench draft) and, when it validates, the
    /// plan the panel shows.
    private func measure(_ key: Int64, draft: AutomationFormModel, text: String) async throws
        -> (AutomationsCLI.ValidateResult, AutomationSavePlan?) {
        let detail = draft.detail
        let isNew = Self.isNewDraft(key)
        let validated = try await cli.validate(text: text, slug: detail.slug, against: isNew ? nil : key,
                                               workbench: isNew && detail.scope == "workbench" ? detail.projectID : nil)
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
        await draft.buffer.flush()
        let generation = (checkGenerations[key] ?? 0) + 1
        checkGenerations[key] = generation
        let text = draft.renderedText()
        validatedTexts[key] = nil
        saving[key] = .validating
        let outcome: Result<(AutomationsCLI.ValidateResult, AutomationSavePlan?), Error>
        do {
            outcome = .success(try await measure(key, draft: draft, text: text))
        } catch {
            outcome = .failure(error)
        }
        guard checkGenerations[key] == generation, drafts[key] === draft,
              saving[key] == .validating else { return }
        guard draft.renderedText() == text else {
            // Typed while the check ran and nothing newer is scheduled: check again.
            if checkTasks[key] == nil { scheduleCheck(key) }
            return
        }
        switch outcome {
        case let .success((validated, plan)):
            lastChecked[key] = validated
            if draft.recipeUnparsed {
                draft.currentParseError = validated.ok ? "" : validated.errors.joined(separator: "\n")
            }
            if let plan {
                validatedTexts[key] = text
                if keepAutoHash[key] != plan.validated.approvalHash {
                    keepAuto[key] = nil
                    keepAutoHash[key] = plan.validated.approvalHash
                }
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
              let form = drafts[key] else { return false }
        return validatedTexts[key] == form.renderedText()
    }

    /// The panel's **Save and Turn On** / **Save and Confirm** (`turnOn`) or
    /// **Save Turned Off**: saves the checked bytes, confirming
    /// `plan.validated.approvalHash` (AUTO-06). Bytes changed since the check
    /// (the page's pending keystroke included) are checked again instead of
    /// saved. A saved automation saved turned off is disabled first; a
    /// turned-on save enables after the confirmed save. Both run whatever the
    /// loaded `enabled` says (the card may have turned it on or off since the
    /// draft was loaded); both are idempotent in Go. `setsEnabled` false (a
    /// built-in's **Save**, whose on/off is its feature keys) only saves:
    /// no disable before it and no enable after it, whatever `turnOn` says.
    package func commit(_ key: Int64, plan: AutomationSavePlan, turnOn: Bool, setsEnabled: Bool = true) async {
        guard saving[key] != .saving, saving[key] != .validating, let draft = drafts[key] else { return }
        await draft.buffer.flush()
        let text = draft.renderedText()
        guard case let .review(checked) = saving[key], checked.validated.approvalHash == plan.validated.approvalHash,
              plan.validated.showsAllFields, validatedTexts[key] == text else {
            await check(key)
            return
        }
        let isNew = Self.isNewDraft(key)
        let disableFirst = setsEnabled && !isNew && !turnOn
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
        if turnOn, setsEnabled {
            do {
                try await cli.setEnabled(saved.automationID, true)
            } catch {
                let notOn = Self.notTurnedOn(Self.message(for: error))
                turnOnPending.insert(key)
                if case let .failed(autoMessage) = saving[key] {
                    saving[key] = .failed(notOn + "\n" + autoMessage)
                } else {
                    saving[key] = .failed(notOn)
                }
            }
        }
        await refresh(saved.automationID)
        // Done only now: a panel watching for `.done` never closes before
        // the turn-on's outcome is known.
        if saving[key] == .saving { saving[key] = .done }
    }

    private func enableAfterSave(_ key: Int64, _ id: Int64) async {
        saving[key] = .saving
        var outcome = SaveState.done
        do {
            try await cli.setEnabled(id, true)
            turnOnPending.remove(key)
        } catch {
            outcome = .failed(Self.notTurnedOn(Self.message(for: error)))
        }
        await refresh(id)
        saving[key] = outcome
    }

    /// **Turn On** after a save or confirm that landed but did not turn the
    /// automation on: only enables it (`.done` on success).
    package func retryTurnOn(_ key: Int64) async {
        guard turnOnPending.contains(key) else { return }
        if let savedID = savedIDs[key], saving[key] != .saving {
            await enableAfterSave(key, savedID)
            return
        }
        guard confirmations[key] != .confirming else { return }
        confirmations[key] = .confirming
        do {
            try await cli.setEnabled(key, true)
            turnOnPending.remove(key)
            await refresh(key)
            confirmations[key] = .done
        } catch {
            await refresh(key)
            confirmations[key] = .failed(Self.confirmedNotEnabled(Self.message(for: error)))
        }
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
        if let form = drafts[id] {
            await form.buffer.flush()
            guard !form.buffer.isDirty else {
                await check(id)
                return
            }
        }
        await confirmForeign(id, shownHash: plan.validated.approvalHash, enable: turnOn)
    }

    private func removeDraftCache(_ key: Int64) {
        guard let draftCache else { return }
        do {
            try draftCache.write { try AutomationDraftCacheQueries.delete($0, conversationID: -key) }
        } catch {
            let reason = error.localizedDescription
            Self.log.error("could not remove the draft cache of conversation \(-key, privacy: .public): \(reason, privacy: .public)")
        }
    }

    /// Saves `text` with `--confirm-hash plan.validated.approvalHash`, then
    /// keeps auto for exactly `plan.keepAuto`; nil (with `saving` failed)
    /// when the save is refused. The draft is gone after a save.
    private func performSave(_ key: Int64, draft: AutomationFormModel, text: String, plan: AutomationSavePlan) async
        -> AutomationsCLI.SaveResult? {
        saving[key] = .saving
        // A new recipe is saved at a slug made from its name, and only where
        // no file exists yet (an empty expected hash).
        let isNew = Self.isNewDraft(key)
        // A new draft's text may come from the chat or a template, whose
        // name the form's fields do not hold: the validated name is the text's.
        let name = Self.isNewDraft(key) && !plan.validated.name.isEmpty ? plan.validated.name : draft.fields.name
        let slug = isNew ? slugHints[key] ?? Self.slug(forName: name) : draft.detail.slug
        let path = isNew ? (draft.detail.path as NSString).appendingPathComponent("\(slug).md")
                         : draft.detail.path
        let saved: AutomationsCLI.SaveResult
        do {
            saved = try await cli.save(text: text, path: path,
                                       confirmHash: plan.validated.approvalHash,
                                       expectContentHash: isNew ? "" : draft.buffer.baseContentHash)
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
        lastChecked[key] = nil
        keepAuto[key] = nil
        keepAutoHash[key] = nil
        // `.saving` until `commit` has turned it on (or not): only then `.done`.
        if !autoFailures.isEmpty {
            saving[key] = .failed("Saved, but auto could not be kept for " + autoFailures.joined(separator: "; "))
        }
        return saved
    }

    // MARK: - Auto

    /// The form's **Auto** toggle for one write tool: `auto … on --hash
    /// <the loaded approval hash>` or `off`. An edit not saved yet is not
    /// what the grant binds: the hash is the recipe's as it is indexed.
    package func setAuto(_ id: Int64, tool: String, on: Bool) async {
        guard let detail = drafts[id]?.detail else { return }
        do {
            try await cli.setAuto(id, tool: tool, on: on, hash: on ? detail.approvalHash : nil)
            autoErrors[id] = nil
        } catch {
            autoErrors[id] = Self.message(for: error)
        }
        await refresh(id)
    }

    // MARK: - Confirm

    /// The panel's confirm of unchanged bytes (`confirmShown`):
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
                turnOnPending.insert(id)
                confirmations[id] = .failed(Self.confirmedNotEnabled(Self.message(for: error)))
                await refresh(id)
                return
            }
        }
        confirmations[id] = .done
        await refresh(id)
    }

    /// A save or confirm that landed after its panel went away: nothing
    /// will open the saved card, so its finished state is dropped (with the
    /// draft) and the next Edit opens the editor on the file, not the card.
    /// Returns the automation a new draft's landed save wrote (the caller
    /// then unlists the draft, `AutomationsViewModel.draftSaved`); nil for
    /// anything else, a failed save included.
    @discardableResult
    package func settleUnwatched(_ key: Int64) -> Int64? {
        var savedNew: Int64?
        if saving[key] == .done {
            if Self.isNewDraft(key) { savedNew = savedIDs[key] }
            discard(key)
        }
        if confirmations[key] == .done {
            confirmations[key] = nil
            discard(key)
        }
        return savedNew
    }

    /// The panel is done with a confirm: its outcome is no longer shown.
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
        id = 0
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
        builtin = nil
    }
}
