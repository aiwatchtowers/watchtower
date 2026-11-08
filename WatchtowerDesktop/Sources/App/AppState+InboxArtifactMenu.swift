import WatchtowerCore

/// The Inbox's ⋯ menus and **+ New Artifact…** (inbox builder B Task 14):
/// they reach the Automations tab's own verbs, editor and run history.
extension AppState {
    /// "Saved. The folder was not created: …" when the Inbox is not built yet.
    static let inboxMenuNotReady = "the Inbox menu is not loaded yet — try again"

    func makeInboxArtifactMenu(strip: ActionStripViewModel) -> InboxArtifactMenuModel {
        InboxArtifactMenuModel(folderMenu: strip.folderMenu, hooks: .init(
            automations: { [weak self] in self?.automationsViewModel },
            setBuiltinEnabled: { [weak self] ids, on in
                await self?.setBuiltinEnabled(ids, on: on) ?? Self.inboxMenuNotReady
            },
            openEditor: { [weak self] id, step in self?.openAutomationEditor(.existing(id), step: step) },
            openRunHistory: { [weak self] id in self?.openAutomationRun(automationID: id, runID: nil) },
            refresh: { [weak strip] in await strip?.refresh() }
        ))
    }

    /// The Automations view model's way to the Inbox menu: the route a save
    /// sets, and the tree the editor's folder line is resolved against.
    func wireInboxFolderRoutes(_ vm: AutomationsViewModel) {
        vm.routeSavedAutomation = { [weak self] in await self?.routeSavedAutomation($0, to: $1, reread: $2) ?? Self.inboxMenuNotReady }
        vm.inboxFolderTree = { [weak self] in self?.actionStripViewModel?.folderMenu.tree }
    }

    /// A saved automation's route to the Inbox folder it was made from
    /// (**+ New Artifact…**) or the editor's folder line names: through the
    /// folder menu at its read revision, after a re-read on **Try Again**.
    /// Nil when it landed.
    func routeSavedAutomation(
        _ automationID: Int64, to destination: InboxFoldersCLI.RouteDestination, reread: Bool
    ) async -> String? {
        guard let menu = actionStripViewModel?.folderMenu else { return Self.inboxMenuNotReady }
        if reread { await menu.reload() }
        return await menu.route(automationID, to: destination)
    }

    /// **+ New Artifact…**: the Automations tab's New flow, the selected
    /// owner folder carried as the route its save sets.
    func newInboxArtifact() {
        guard let automationsViewModel else { return }
        let route = actionStripViewModel.flatMap { strip in
            InboxArtifactMenuModel.newArtifactRoute(strip.folderMenu.tree, selected: strip.folderMenu.selectedFolderID)
        }
        automationsViewModel.showNew(AutomationNewFlow(route: route))
        navigateToAutomations()
    }
}
