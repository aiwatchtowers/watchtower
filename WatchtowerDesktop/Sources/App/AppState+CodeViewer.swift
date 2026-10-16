import GRDB

/// The Workbench code viewer's wiring, split out of `initWorkbenches`.
extension AppState {
    /// The code viewer's centers (index, Open Quickly, navigation, Usages,
    /// questions, hand-off) follow the new Workbench view model.
    func wireCodeViewer(_ vm: WorkbenchesViewModel, dbPool: DatabasePool) {
        vm.codeFiles.codeIndex = codeIndexCenter
        openQuicklyCenter.workbenches = vm
        codeNavigationCenter.workbenches = vm
        vm.codeFiles.navigation = codeNavigationCenter
        codeUsagesCenter.useWorkspace(dbPool.path)
        codeUsagesCenter.workbenches = vm
        codeUsagesCenter.navigation = codeNavigationCenter
        codeNavigationCenter.usages = codeUsagesCenter
        vm.codeFiles.usages = codeUsagesCenter
        codeQuestionCenter.workbenches = vm
        codeQuestionCenter.navigation = codeNavigationCenter
        codeQuestionCenter.codeIndex = codeIndexCenter
        codeQuestionCenter.embeddedChats = embeddedChatCenter
        codeQuestionCenter.dbPool = dbPool
        codeQuestionCenter.dictation = dictationCenter
        codeQuestionCenter.modelSuggestions = { [aiModelCatalog] in aiModelCatalog.suggestions(for: $0.rawValue) }
        codeQuestionCenter.usages = codeUsagesCenter
        openQuicklyCenter.questions = codeQuestionCenter
        vm.codeFiles.questions = codeQuestionCenter
        codeHandoffCenter.workbenches = vm
        codeHandoffCenter.terminalCenter = terminalCenter
        codeHandoffCenter.dbPool = dbPool
        codeQuestionCenter.handoff = codeHandoffCenter
        openQuicklyCenter.onHandToClaude = { [weak self] query, project, root in
            guard let self else { return }
            codeHandoffCenter.handQuery(query, project: project, origin: codeQuestionCenter.openFileOrigin(root))
        }
    }
}
