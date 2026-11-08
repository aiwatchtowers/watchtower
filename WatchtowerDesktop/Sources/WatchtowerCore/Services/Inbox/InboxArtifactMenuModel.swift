import Foundation
import Observation

/// The Inbox's artifact ⋯ and Needs approval's ⋯ (spec "The Inbox screen" →
/// Menus, plan B Task 14). Every entry goes through the verb the Automations
/// tab calls — `AutomationsViewModel.runNow`/`setEnabled`/`delete` for a
/// recipe, the built-in's own card (`AutomationsViewModel.builtinCard`) for
/// a built-in, the tab's editor and run history — so the tab and the Inbox
/// share one per-automation busy guard and one Delete cleanup. Only Move to
/// Folder ▸ has no tab twin: it is the folder menu's `route`. A press's
/// failure shows on its artifact's header (`headerErrors`), never read from
/// the tab-wide `lastError`. Owned by `AppState`, so a press still running
/// when the Inbox leaves the screen lands where the Inbox finds it again.
@MainActor
@Observable
package final class InboxArtifactMenuModel {
    /// What the model reaches outside the Inbox; the app wires them, tests fake them.
    package struct Hooks {
        /// The Automations tab's view model; nil until it is built (every entry is off).
        package var automations: @MainActor () -> AutomationsViewModel?
        /// A built-in's Turn On / Turn Off by feature ids (`AppState.setBuiltinEnabled`).
        package var setBuiltinEnabled: @MainActor ([String], Bool) async -> String?
        /// The tab's editor on `automationID` at `step` (`AppState.openAutomationEditor`).
        package var openEditor: @MainActor (_ automationID: Int64, AutomationEditorStep) -> Void
        /// The automation's card in the Automations tab (`AppState.openAutomationRun`).
        package var openRunHistory: @MainActor (_ automationID: Int64) -> Void
        /// Re-reads the Inbox after a press that landed.
        package var refresh: @MainActor () async -> Void

        package init(
            automations: @escaping @MainActor () -> AutomationsViewModel?,
            setBuiltinEnabled: @escaping @MainActor ([String], Bool) async -> String?,
            openEditor: @escaping @MainActor (Int64, AutomationEditorStep) -> Void,
            openRunHistory: @escaping @MainActor (Int64) -> Void,
            refresh: @escaping @MainActor () async -> Void
        ) {
            self.automations = automations
            self.setBuiltinEnabled = setBuiltinEnabled
            self.openEditor = openEditor
            self.openRunHistory = openRunHistory
            self.refresh = refresh
        }
    }

    /// A Delete… waiting for the owner's confirmation.
    package struct PendingDelete: Equatable, Sendable {
        package let outputID: Int64
        package let automationID: Int64
        package let name: String
    }

    /// The last failed (or busy) ⋯ press, by output id; the next press on
    /// that artifact clears it.
    package private(set) var headerErrors: [Int64: String] = [:]
    /// Needs approval ⋯'s last failed (or busy) press.
    package private(set) var approvalsError: String?
    package private(set) var pendingDelete: PendingDelete?
    /// The automations with an Inbox press running: a second press is ignored.
    package private(set) var pressing: Set<Int64> = []
    /// Needs approval's Turn On / Turn Off runs.
    package private(set) var approvalsPressing = false

    @ObservationIgnored private let folderMenu: InboxFolderMenuModel
    @ObservationIgnored private let hooks: Hooks

    package init(folderMenu: InboxFolderMenuModel, hooks: Hooks) {
        self.folderMenu = folderMenu
        self.hooks = hooks
    }

    nonisolated package static let notIndexed = "Needs approval's automation is not indexed yet — try again after the next sync"

    // MARK: - What the menu shows

    /// The indexed automation `id` (the tab's list).
    package func automation(_ id: Int64) -> Automation? {
        hooks.automations()?.items.first { $0.id == id }?.automation
    }

    /// The artifact ⋯ of `card`: a built-in has no Delete…, Needs
    /// approval's automation no Move to Folder, a built-in without Run Now
    /// none; Turn Off / Turn On follows `enabled` — a built-in's from its
    /// `show` (its features), as the tab's card reads it.
    package func content(for card: AutomationOutputCard) -> InboxArtifactMenuContent {
        let automation = automation(card.automationID)
        let builtin = automation?.isBuiltin ?? false
        let detail = automation.flatMap { builtin ? hooks.automations()?.builtinCard($0).detail : nil }
        let offersRunNow = builtin ? detail?.runNow ?? false : true
        return InboxArtifactMenuContent(
            isBuiltin: builtin,
            offersRunNow: offersRunNow,
            movable: automation?.builtinID != InboxFolderQueries.needsApprovalBuiltinID,
            isEnabled: detail?.enabled ?? automation?.enabled ?? true,
            folders: folderMenu.content.rows,
            currentFolderID: folderMenu.tree.routes[card.automationID])
    }

    /// A built-in's ⋯ needs its `show` (whether it offers Run Now): read once.
    package func prepare(_ card: AutomationOutputCard) async {
        guard let automation = automation(card.automationID), automation.isBuiltin,
              let builtin = hooks.automations()?.builtinCard(automation), builtin.detail == nil else { return }
        await builtin.load()
    }

    /// A folder list's artifacts: each built-in reads its `show` once, so a
    /// row's context menu offers Run Now before its reading pane opened.
    package func prepare(_ cards: [AutomationOutputCard]) async {
        var seen: Set<Int64> = []
        for card in cards where seen.insert(card.automationID).inserted { await prepare(card) }
    }

    /// The entries are off: the tab's model is not built, the automation is
    /// not indexed, or a call on it runs (here or from the Automations tab).
    package func isDisabled(_ card: AutomationOutputCard) -> Bool {
        guard let vm = hooks.automations(), let automation = automation(card.automationID) else { return true }
        return isWorking(automation, vm)
    }

    /// A press on this artifact's automation runs, from here or the tab.
    package func isWorking(_ card: AutomationOutputCard) -> Bool {
        guard let vm = hooks.automations(), let automation = automation(card.automationID) else {
            return pressing.contains(card.automationID)
        }
        return isWorking(automation, vm)
    }

    private func isWorking(_ automation: Automation, _ vm: AutomationsViewModel) -> Bool {
        pressing.contains(automation.id) || vm.busy[automation.id] != nil
            || (automation.isBuiltin && vm.builtinCard(automation).isWorking)
    }

    // MARK: - The artifact ⋯

    /// Carries out a press in `card`'s ⋯. Delete… only asks; `confirmDelete`
    /// deletes.
    package func perform(_ command: InboxMenuCommand, on card: AutomationOutputCard) async {
        let id = card.automationID
        guard !pressing.contains(id), let vm = hooks.automations(), let automation = automation(id) else { return }
        headerErrors[card.id] = nil
        switch command {
        case .editCollects: hooks.openEditor(id, .collects)
        case .editLook: hooks.openEditor(id, .look)
        case .schedule: hooks.openEditor(id, .schedule)
        case .runHistory: hooks.openRunHistory(id)
        case .delete:
            guard !automation.isBuiltin else { return }
            pendingDelete = PendingDelete(outputID: card.id, automationID: id, name: automation.name)
        case .runNow:
            await press(id, outputID: card.id) {
                automation.isBuiltin ? await vm.builtinCard(automation).runNow() : await vm.runNow(id)
            }
        case .turnOn, .turnOff:
            let on = command == .turnOn
            await press(id, outputID: card.id) {
                automation.isBuiltin
                    ? await vm.builtinCard(automation).setEnabled(on, self.hooks.setBuiltinEnabled)
                    : await vm.setEnabled(id, on)
            }
        case let .moveTo(folderID):
            await press(id, outputID: card.id) {
                await self.folderMenu.route(id, to: folderID).map { .failed("Couldn't move it: \($0)") } ?? .done
            }
        default:
            return
        }
    }

    /// The confirmation's **Delete** of `pending` (taken when pressed: the
    /// dialog's dismissal clears `pendingDelete` before this runs): the
    /// tab's `delete`, with its cleanup.
    package func confirmDelete(_ pending: PendingDelete) async {
        guard let vm = hooks.automations() else { return }
        if pendingDelete == pending { pendingDelete = nil }
        await press(pending.automationID, outputID: pending.outputID) { await vm.delete(pending.automationID) }
    }

    package func cancelDelete() {
        pendingDelete = nil
    }

    private func press(_ id: Int64, outputID: Int64, _ call: () async -> AutomationCallResult) async {
        guard !pressing.contains(id) else { return }
        pressing.insert(id)
        defer { pressing.remove(id) }
        switch await call() {
        case .done: await hooks.refresh()
        case .busy: headerErrors[outputID] = AutomationCallResult.busyText
        case let .failed(message): headerErrors[outputID] = message
        }
    }

    // MARK: - Needs approval's ⋯

    /// The `needs-approval` built-in's automation, once indexed.
    package var approvalsAutomation: Automation? {
        hooks.automations()?.items.first { $0.automation.builtinID == InboxFolderQueries.needsApprovalBuiltinID }?
            .automation
    }

    /// Edit the Look…, Turn Off / Turn On (the built-in's own card, else its
    /// feature directly), Run History.
    package func performApprovals(_ command: InboxMenuCommand) async {
        guard !approvalsPressing else { return }
        approvalsError = nil
        let automation = approvalsAutomation
        switch command {
        case .editLook, .runHistory:
            guard let automation else {
                approvalsError = Self.notIndexed
                return
            }
            if command == .editLook { hooks.openEditor(automation.id, .look) } else { hooks.openRunHistory(automation.id) }
        case .turnOn, .turnOff:
            let on = command == .turnOn
            approvalsPressing = true
            defer { approvalsPressing = false }
            let result: AutomationCallResult
            if let automation, let vm = hooks.automations() {
                result = await vm.builtinCard(automation).setEnabled(on, hooks.setBuiltinEnabled)
            } else {
                result = await hooks.setBuiltinEnabled([ActionStripViewModel.approvalsFeatureID], on)
                    .map(AutomationCallResult.failed) ?? .done
            }
            switch result {
            case .done: await hooks.refresh()
            case .busy: approvalsError = AutomationCallResult.busyText
            case let .failed(message): approvalsError = message
            }
        default:
            return
        }
    }

    // MARK: - + New Artifact…

    /// **+ New Artifact…** from the selected folder: an owner folder is the
    /// route its save sets; the root and Needs approval send none.
    package static func newArtifactRoute(_ tree: InboxFolderTree, selected: Int64) -> InboxNewArtifactRoute? {
        guard let folder = tree.folder(selected), folder.kind == .owner else { return nil }
        return InboxNewArtifactRoute(folderID: folder.id, title: folder.title)
    }
}
