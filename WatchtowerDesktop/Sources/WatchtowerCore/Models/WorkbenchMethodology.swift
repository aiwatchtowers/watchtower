import Foundation

/// One of a workbench's three methodology settings (spec 2026-10-15 §8): the
/// preset skill, the ask guard and the finish check. Go owns the values and
/// their resolution (`internal/workbenchmethod`); the Desktop shows them and
/// sets them only through `watchtower workbench methodology`.
package enum WorkbenchMethodologyKey: String, CaseIterable, Sendable {
    case preset
    case askGuard
    case finishCheck

    /// The choice that drops the personal setting (the CLI's value `file`):
    /// the folder's workflow.md applies, else the built-in default.
    package static let fromFile = "file"

    /// The CLI flag that sets it.
    package var flag: String {
        switch self {
        case .preset: "--preset"
        case .askGuard: "--ask-guard"
        case .finishCheck: "--finish-check"
        }
    }

    package var title: String {
        switch self {
        case .preset: "Methodology"
        case .askGuard: "Ask guard"
        case .finishCheck: "Finish check"
        }
    }

    /// The picker's choices, From folder file (Default for a check) first.
    package var choices: [String] {
        switch self {
        case .preset: [Self.fromFile, "watchtower-flow", "none"]
        case .askGuard: [Self.fromFile, "strict", "soft", "off"]
        case .finishCheck: [Self.fromFile, "on", "off"]
        }
    }

    /// A check's `file` choice reads Default: the folder file never sets a
    /// check (board #558).
    package func choiceLabel(_ choice: String) -> String {
        switch (self, choice) {
        case (.preset, Self.fromFile): "From folder file"
        case (_, Self.fromFile): "Default"
        case (_, "watchtower-flow"): "Watchtower flow"
        default: choice.prefix(1).uppercased() + String(choice.dropFirst())
        }
    }

    /// What a value does; soft names the Desktop-down limit (spec §7.1).
    package func choiceHelp(_ choice: String) -> String {
        switch (self, choice) {
        case (.preset, Self.fromFile):
            "Use the folder's .watchtower/workflow.md, else the built-in default."
        case (_, Self.fromFile):
            "Use the built-in default. The folder's workflow.md cannot turn this check down; only your setting here can."
        case (.preset, "watchtower-flow"):
            "Watchtower's default methodology: features, specs and plans become targets, and reviewer agents put work in review."
        case (.preset, "none"):
            "No methodology skill: the agent follows the core workbench skill and the folder rules only."
        case (.askGuard, "strict"):
            "A request left as plain text is sent back until the agent files an ask; a short question may stand while you are in the session."
        case (.askGuard, "soft"):
            "Nothing is sent back. A question asked in plain text is raised as an ask if it waits — "
                + "only in sessions run in Watchtower's terminal; elsewhere it just passes. "
                + "Raising needs the Watchtower app running: a question asked while it is closed waits until it starts."
        case (.askGuard, "off"):
            "No ask check at the end of a turn, and the agent's own question tool is allowed."
        case (.finishCheck, "on"):
            "A turn that reports the work complete without finish_session is sent back."
        case (.finishCheck, "off"):
            "No reminder: a session the agent does not finish ends as Stopped, without a summary."
        default:
            ""
        }
    }
}

/// `watchtower workbench methodology <id> --json`: the personal settings, the
/// effective values, where each comes from (`default`, `personal`, `file`),
/// the folder file's state and what the call itself did.
package struct WorkbenchMethodologyState: Decodable, Equatable, Sendable {
    package struct Values: Decodable, Equatable, Sendable {
        package let preset: String
        package let askGuard: String
        package let finishCheck: String

        package subscript(key: WorkbenchMethodologyKey) -> String {
            switch key {
            case .preset: preset
            case .askGuard: askGuard
            case .finishCheck: finishCheck
            }
        }

        enum CodingKeys: String, CodingKey {
            case preset
            case askGuard = "ask_guard"
            case finishCheck = "finish_check"
        }
    }

    package struct File: Decodable, Equatable, Sendable {
        package let present: Bool
        package let error: String
        package let bodyChars: Int
        package let truncated: Bool
        /// The check settings the file asks for that were ignored
        /// ("ask_guard: off") — only for a check with no personal value:
        /// only a personal setting turns a check down (board #558). nil from
        /// a CLI that predates the key.
        package let ignored: [String]?

        enum CodingKeys: String, CodingKey {
            case present, error, truncated, ignored
            case bodyChars = "body_chars"
        }
    }

    package let id: Int64
    package let ok: Bool
    package let error: String
    package let personal: Values
    package let effective: Values
    package let sources: Values
    /// When each check was carried over from workflow.md by the board #558
    /// upgrade (RFC 3339; "" = the owner's pick); nil from an older CLI.
    package let carriedAt: Values?
    package let file: File
    package let fileCreated: Bool
    package let fileCreateError: String
    package let installRan: Bool
    package let installOK: Bool
    package let installError: String
    /// What the install left in `.claude/skills` and `.agents/skills` (a
    /// devpack state; empty without the core skill there or when no install
    /// ran) and whether an edited pre-v10 core keeps the single-file layout.
    package let installFlow: String
    package let installCodexFlow: String
    package let installSingleFileLayout: Bool

    enum CodingKeys: String, CodingKey {
        case id, ok, error, personal, effective, sources, file
        case carriedAt = "carried_at"
        case fileCreated = "file_created"
        case fileCreateError = "file_create_error"
        case installRan = "install_ran"
        case installOK = "install_ok"
        case installError = "install_error"
        case installFlow = "install_flow"
        case installCodexFlow = "install_codex_flow"
        case installSingleFileLayout = "install_single_file_layout"
    }

    /// The picker's selection: the personal value, else From folder file.
    package func choice(_ key: WorkbenchMethodologyKey) -> String {
        let mine = personal[key]
        return mine.isEmpty ? WorkbenchMethodologyKey.fromFile : mine
    }

    /// Under a picker on From folder file: what applies and where it comes
    /// from; nil when a personal value is set.
    package func effectiveLine(_ key: WorkbenchMethodologyKey) -> String? {
        guard personal[key].isEmpty else { return nil }
        let value = key.choiceLabel(effective[key])
        return sources[key] == "file" ? "Now \(value), from .watchtower/workflow.md" : "Now \(value), the built-in default"
    }

    /// Under a personal value the upgrade carried over from workflow.md
    /// (board #558): that the owner did not pick it, and when; nil otherwise.
    /// The date is shown in the viewer's time zone (`dateStyle` medium).
    package func carriedLine(_ key: WorkbenchMethodologyKey, timeZone: TimeZone = .current) -> String? {
        guard !personal[key].isEmpty, let at = carriedAt?[key], !at.isEmpty,
              let date = ISO8601DateFormatter().date(from: at) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = timeZone
        return "Carried over from workflow.md on \(formatter.string(from: date)) — the file no longer sets it."
    }

    package var fileButtonTitle: String { file.present ? "Open workflow.md" : "Create workflow.md" }

    /// Why the folder file was ignored, that it was cut, or that it asks to
    /// turn a check down, which only a personal setting can (board #558);
    /// nil otherwise.
    package var fileNote: String? {
        if !file.error.isEmpty { return "workflow.md was ignored: \(file.error). The built-in defaults apply." }
        var notes: [String] = []
        if file.truncated { notes.append("workflow.md is longer than 64 KiB; Watchtower reads only its first 64 KiB.") }
        if let ignored = file.ignored, !ignored.isEmpty {
            notes.append("workflow.md asks for \(ignored.joined(separator: ", ")); that is ignored. "
                + "Only your settings can turn a check down: to turn it down, pick the value above.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// After a preset change: preset none kept an edited or foreign
    /// watchtower-flow copy (spec §4.3), or an edited pre-v10 core keeps its
    /// own methodology; nil otherwise. Go's `keptFlowNote` says the same.
    package var installNote: String? {
        let kept: Set<String> = ["drifted", "foreign"]
        if effective.preset == "none", [installFlow, installCodexFlow].contains(where: kept.contains) {
            return "Your edited watchtower-flow skill was kept; delete it yourself to drop the methodology."
        }
        if installSingleFileLayout {
            return "Your edited skill keeps the old single-file layout; delete it to take the v10 core and preset."
        }
        return nil
    }

    /// What the call failed to do; nil when everything it ran succeeded.
    package var failure: String? {
        if !ok { return "Could not save the setting: \(error)" }
        if !installOK {
            return "The setting was saved, but the folder's skills were not updated: \(installError). Use Re-run Setup."
        }
        if !fileCreateError.isEmpty { return "Could not create workflow.md: \(fileCreateError)" }
        return nil
    }
}
