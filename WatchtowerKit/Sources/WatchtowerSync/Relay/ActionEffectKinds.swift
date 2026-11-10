import Foundation

/// The slice kinds the hub refreshes after it applies an action kind: the phone's mirror of the Go hub's
/// `handlers.NudgeTable`. The first slice of one of them after the answer ends an action's timing (relay client
/// Phase 4). The `action_effect_kinds` section of `hub_contract_cases.json` pins both tables, so a new handler nudge
/// fails one side until both change. A kind this build does not know has no entry, and so no timing.
public enum ActionEffectKinds {
    private static let board = ["workbench", "workbench_target", "workbench_comment"]
    private static let session = ["terminal_session", "session_timeline"]

    static let table: [String: [String]] = [
        "ask_answer": ["owner_ask", "ask_alert"],
        "board_target_status": board,
        "board_target_priority": board,
        "board_comment_add": board,
        "board_comment_reply": board,
        "board_target_create": board,
        "automation_run": ["workbench"],
        "permission_answer": ["permission_request", "terminal_session"],
        "session_interrupt": ["terminal_session"],
        "session_report_request": ["session_report"],
        "session_chat_request": ["session_chat"],
        "session_input": session,
        "session_finish_request": session,
        "session_input_cancel": session,
        "session_start": session,
        "session_stop": session
    ]

    public static func kinds(for actionKind: String) -> [String] {
        table[actionKind] ?? []
    }
}
