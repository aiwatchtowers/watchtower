import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The automation editor before a save: the Draft panel with "Sessions it
/// starts" (one prompt long enough to fold, one clipped), and a pending
/// `save_automation` card of the same text with its scope line and sessions.
@MainActor
enum AutomationShotFixtures {
    private static let recipe = "---\nname: \"Release button\"\ntrigger:\n  button: \"Release\"\n---\n"

    private static let steps: [[String: Any]] = [
        ["seq": 1, "kind": "session", "name": "claude", "status": "dry_run",
         "args": #"{"agent":"claude","prompt":"Run /release for acme. Cut the version, tag it and write the notes; "#
             + #"when the build is green, publish the release and "#
             + #"post the notes to #releases, then report the version number.","title":"Release"}"#,
         "result": "", "permission": "session:start@claude", "error": "", "tokens": 0],
        ["seq": 2, "kind": "session", "name": "claude", "status": "dry_run",
         "args": #"{"agent":"claude","prompt":"Check the rel"#, "result": "", "permission": "session:start@claude",
         "error": "", "tokens": 0],
        ["seq": 3, "kind": "output", "name": "report", "status": "dry_run", "args": #"{"title":"Release"}"#,
         "result": "", "permission": "", "error": "", "tokens": 0]
    ]

    private static func cacheLine() throws -> String {
        let entry: [String: Any] = [
            "recipe_text": recipe,
            "result": [
                "ok": true, "errors": [],
                "manifest": ["name": "Release button", "slug": "release-button", "trigger_kind": "button",
                             "trigger": "Release", "permissions": ["session:start@claude"], "outputs": ["report"],
                             "budget_tokens": 20000, "budget_minutes": 30],
                "dry_run": ["steps": steps, "tokens": 0, "status": "succeeded", "error": ""]
            ],
            "at": "2026-10-20T09:00:00Z"
        ]
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    static func draftPanel() -> AnyView {
        do {
            let model = AutomationDraftPanelModel(newest: AutomationDraftEntry.newest(inCache: try cacheLine()))
            return AnyView(AutomationDraftPanel(model: model, canAct: true, actionHelp: nil,
                                                onCancel: {}, onDryRunAgain: {}, onSave: {}))
        } catch {
            return failure(error)
        }
    }

    static func saveCard() -> AnyView {
        do {
            let args: [String: Any] = [
                "scope": "workbench", "workbench_id": 3, "path": "/acme/.watchtower/automations/release-button.md",
                "name": "Release button", "slug": "release-button", "trigger_kind": "button",
                "trigger_spec": ["button": ["label": "Release"]], "permissions": ["session:start@claude"],
                "outputs": ["report"], "widening": ["session:start@claude"], "budget_tokens": 20000,
                "budget_minutes": 30, "is_new": true, "recipe_text": recipe, "previous_recipe_text": "",
                "dry_run_summary": "Starts one release session, then reports its summary."
            ]
            let json = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8))
            let action = AgentAction(row: Row([
                "id": 1, "tool": "save_automation", "args_json": json, "reason": "a Release button",
                "status": "pending", "turn_id": "t1"
            ]))
            let sessions = AutomationDraftPanelModel.dryRunSessions(inCache: try cacheLine())
            return AnyView(AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {},
                                               onRetry: {}, latestDraftText: recipe, draftSessions: sessions))
        } catch {
            return failure(error)
        }
    }

    private static func failure(_ error: Error) -> AnyView {
        XCTFail("automation shot fixture failed: \(error)")
        return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
    }
}
