import WatchtowerCore

/// The Inbox's ⋯ menus and **+ New Artifact…** (inbox builder B Task 14):
/// they reach the Automations tab's own verbs, editor and run history.
extension AppState {
    /// "Saved. The folder was not created: …" when the Inbox is not built yet.
    static let inboxMenuNotReady = "the Inbox menu is not loaded yet — try again"

    func makeInboxArtifactMenu(strip: ActionStripViewModel) -> InboxArtifactMenuModel {
        InboxArtifactMenuModel(folderMenu: strip.folderMenu, hooks: .init(
            automations: { [weak self] in self?.automationsViewModel },
            // Nil (landed) stays nil: only a gone app state is "not ready".
            setBuiltinEnabled: { [weak self] ids, on in
                guard let self else { return Self.inboxMenuNotReady }
                return await setBuiltinEnabled(ids, on: on)
            },
            openEditor: { [weak self] id, step in self?.openAutomationEditor(.existing(id), step: step) },
            openRunHistory: { [weak self] id in self?.openAutomationRun(automationID: id, runID: nil) },
            refresh: { [weak strip] in await strip?.refresh() }
        ))
    }

    /// **+ New Artifact…**'s save routes through `routeSavedAutomation`;
    /// its nil (landed) stays nil — only a gone app state is "not ready".
    func wireInboxRoute(_ vm: AutomationsViewModel) {
        vm.routeSavedAutomation = { [weak self] automationID, folderID, reread in
            guard let self else { return Self.inboxMenuNotReady }
            return await routeSavedAutomation(automationID, to: folderID, reread: reread)
        }
    }

    /// The Automations tab's template panels: an install re-reads the list
    /// and the first copy's card, and its copies go to the Inbox folder of
    /// the New flow it started from (**+ New Artifact…**).
    func makeTemplatePanels(vm: AutomationsViewModel, cli: AutomationsCLI) -> AutomationTemplatePanels {
        AutomationTemplatePanels { [weak vm] template, scope in
            AutomationTemplatePanelModel(
                template: template, scope: scope, cli: cli,
                installed: { ids in await vm?.templateInstalled(name: template.name, scope: scope, ids: ids) },
                refresh: { id in
                    vm?.refresh()
                    if let id { await vm?.loadDetail(id) }
                }
            )
        }
    }

    /// A saved automation's route to the Inbox folder it was made from
    /// (**+ New Artifact…**): through the folder menu at its read revision,
    /// after a re-read on **Try Again**. Nil when it landed.
    func routeSavedAutomation(_ automationID: Int64, to folderID: Int64, reread: Bool) async -> String? {
        guard let menu = actionStripViewModel?.folderMenu else { return Self.inboxMenuNotReady }
        if reread { await menu.reload() }
        return await menu.route(automationID, to: folderID)
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
