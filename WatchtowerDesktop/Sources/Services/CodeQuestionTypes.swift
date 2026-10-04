import Foundation
import WatchtowerCore

/// The editor page's half of code questions (spec §9.2, §8.5): the Files
/// pane's `MonacoEditorView.Coordinator`, a fake in tests.
@MainActor
protocol CodeQuestionPage: AnyObject {
    /// `askAI()`: the page posts `selection`, then `askAI`, for the file on
    /// screen; false = no file (or the page could not be asked).
    func requestAskAI() async -> Bool
    /// The selection's box (a caret's when empty) in the page's points, top
    /// left origin; nil = no file on screen or scrolled away.
    func selectionRect() async -> CGRect?
    func proposeEdit(bufferID: String, range: CodeTextRange, text: String)
    func clearProposal(bufferID: String)
    func applyEdit(bufferID: String, range: CodeTextRange, text: String, expected: String) async -> CodeEditApplyResult
    /// The question popover, pointing at `rect` (page points); false when
    /// it could not be shown (the editor is in no window).
    func presentQuestionPopover(at rect: CGRect) -> Bool
    func closeQuestionPopover()
}

/// The popover's quick actions (spec §9.2): each sends a fixed prompt.
enum CodeQuestionQuickAction: CaseIterable, Identifiable {
    case explain
    case findProblems
    case whereUsed
    case suggestChange

    var id: Self { self }

    var title: String {
        switch self {
        case .explain: "Explain"
        case .findProblems: "Find problems"
        case .whereUsed: "Where is it used?"
        case .suggestChange: "Suggest a change"
        }
    }

    var prompt: String {
        switch self {
        case .explain: "Explain what this code does."
        case .findProblems: "Find problems in this code: bugs, unhandled cases and risky assumptions."
        case .whereUsed: "Where is this used? Answer only from the usage locations attached to this question "
            + "(Watchtower's search of the workbench), citing each as path:line; say so when none are attached."
        case .suggestChange: "Suggest a change to this code."
        }
    }
}

/// A code question's conversation as every surface opens it: the popover,
/// Open Quickly's answer card and the Questions tab.
struct CodeQuestionRef {
    let project: Workbench
    let conversationID: Int64
    /// What `context_id` names; `path` "" for Open Quickly with no file open.
    let origin: CodeQuestionOrigin
}

/// What asking from Open Quickly did.
enum CodeQuestionStart: Equatable {
    case started(conversationID: Int64)
    case failed(String)
}
