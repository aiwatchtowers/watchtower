import AppKit
import SwiftUI
import WatchtowerCore

/// What a hint's fix button does (`Fix` in `internal/agentreport/hints.go`).
enum AgentHintFixAction: Equatable {
    /// Copy these `permissions.allow` lines.
    case copyRules([String])
    /// A session uuid: its analytics.
    case openSession(String)
    /// The workbench's Waiting for you stack.
    case openAsks
    /// A path relative to the workbench folder, in the Files pane.
    case openFile(String)

    /// The button for `fix`; nil for no fix, a kind this app does not know
    /// (a newer CLI) or one missing what it acts on.
    static func make(_ fix: AgentHintFix?) -> Self? {
        guard let fix else { return nil }
        let ref = fix.ref ?? ""
        switch fix.kind {
        case "copy_allow_rules":
            guard let rules = fix.rules, !rules.isEmpty else { return nil }
            return .copyRules(rules)
        case "open_session": return ref.isEmpty ? nil : .openSession(ref)
        case "open_asks": return .openAsks
        case "open_file": return ref.isEmpty ? nil : .openFile(ref)
        default: return nil
        }
    }

    /// The rules as lines of a JSON array, one quoted rule per line, ready
    /// to paste into `permissions.allow`.
    static func copyText(_ rules: [String]) -> String {
        rules.map(quoted).joined(separator: ",\n")
    }

    var title: String {
        switch self {
        case .copyRules: "Copy Allow Rules"
        case .openSession: "Open Session"
        case .openAsks: "Open Waiting for You"
        case let .openFile(path): "Open \(path)"
        }
    }

    var help: String {
        switch self {
        case .copyRules: "Copies the lines for permissions.allow in .claude/settings.json"
        case .openSession: "Show this session's analytics"
        case .openAsks: "Show the asks waiting for you"
        case .openFile: "Open the file in Files"
        }
    }

    private static func quoted(_ rule: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(rule), let text = String(data: data, encoding: .utf8) else {
            return "\"\(rule)\""
        }
        return text
    }
}

/// A hint's fix as a button; nothing for a hint without one.
struct AgentHintFixButton: View {
    let fix: AgentHintFix?
    let actions: AgentAnalyticsActions
    /// Copy Allow Rules reads "Copied" for a moment after a click.
    @State private var copied = false

    var body: some View {
        if let action = AgentHintFixAction.make(fix) {
            let noAsks = action == .openAsks && !actions.asksWaiting
            Button(copied ? "Copied" : action.title) { perform(action) }
                .controlSize(.small)
                .disabled(noAsks)
                .help(noAsks ? "No asks are waiting now" : action.help)
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
        }
    }

    private func perform(_ action: AgentHintFixAction) {
        switch action {
        case let .copyRules(rules):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AgentHintFixAction.copyText(rules), forType: .string)
            copied = true
        case let .openSession(uuid): actions.openSession(uuid)
        case .openAsks: actions.openAsks()
        case let .openFile(path): actions.openFile(path)
        }
    }
}
