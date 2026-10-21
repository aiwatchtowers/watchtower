import Foundation

/// The Desktop's write path for automations: every write but an inbox
/// output's read/done/dismiss marks goes through `watchtower automations …`
/// (spec §9.6). Result structs decode the pinned `--json` keys of
/// cmd/automations*.go; arrays default to `[]` and unknown keys are ignored.
/// A non-zero exit surfaces as the runner's `CLIRunnerError.nonZeroExit`
/// carrying the CLI's stderr.
package struct AutomationsCLI {
    // swiftlint:disable:next type_name
    package enum Op: Equatable, Sendable {
        case run(Int64, rerunOf: Int64? = nil)
        case dryRun(Int64)
        case show(Int64)
        case validate(file: String, against: Int64?, workbench: Int64? = nil)
        case save(file: String, path: String, confirmHash: String, expectContentHash: String)
        case confirm(Int64, hash: String)
        case setEnabled(Int64, Bool)
        case auto(Int64, tool: String, on: Bool, hash: String?)
        case delete(Int64)
        case cancel(runID: Int64)
        case wake
        case templates
        case installTemplate(name: String, workbenchID: Int64?, params: [String: String] = [:])
        case renderTemplate(name: String, workbenchID: Int64?, params: [String: String])
        case sessionLaunched(step: Int64, session: Int64)
        case sessionEnded(step: Int64, status: SessionEnd, error: String?)
        case rescan(workbenchID: Int64)
        /// The owner's press of Reply action `action` of Inbox card `outputID`.
        case reply(outputID: Int64, action: Int)
    }

    /// How a `session()` step's session ended, as `session-ended --status`
    /// takes it: its process ended unfinished, or it never launched.
    package enum SessionEnd: String, Equatable, Sendable {
        case stopped
        case launchFailed = "launch_failed"
    }

    private let runner: any CLIRunnerProtocol

    package init(runner: any CLIRunnerProtocol) {
        self.runner = runner
    }

    // swiftlint:disable:next cyclomatic_complexity
    package static func args(_ op: Op) -> [String] {
        switch op {
        case let .run(id, rerunOf):
            var out = ["automations", "run", String(id)]
            if let rerunOf { out += ["--rerun-of", String(rerunOf)] }
            return out + ["--json"]
        case let .dryRun(id):
            return ["automations", "dry-run", String(id), "--json"]
        case let .show(id):
            return ["automations", "show", String(id), "--json"]
        case let .validate(file, against, workbench):
            precondition(against == nil || workbench == nil, "validate takes --against or --workbench, not both")
            var out = ["automations", "validate", file]
            if let against { out += ["--against", String(against)] }
            if let workbench { out += ["--workbench", String(workbench)] }
            return out + ["--json"]
        case let .save(file, path, confirmHash, expectContentHash):
            // --expect-content-hash is always passed: "" means the file must not exist.
            return ["automations", "save", "--file", file, "--path", path, "--confirm-hash", confirmHash,
                    "--expect-content-hash", expectContentHash, "--json"]
        case let .confirm(id, hash):
            return ["automations", "confirm", String(id), "--hash", hash]
        case let .setEnabled(id, on):
            return ["automations", on ? "enable" : "disable", String(id)]
        case let .auto(id, tool, on, hash):
            var out = ["automations", "auto", String(id), tool, on ? "on" : "off"]
            if on, let hash { out += ["--hash", hash] }
            return out + ["--json"]
        case let .delete(id):
            return ["automations", "delete", String(id)]
        case let .cancel(runID):
            return ["automations", "cancel", String(runID)]
        case .wake:
            return ["automations", "wake"]
        case .templates:
            return ["automations", "templates", "--json"]
        case let .installTemplate(name, workbenchID, params):
            return templateArgs(name: name, workbenchID: workbenchID, params: params) + ["--json"]
        case let .renderTemplate(name, workbenchID, params):
            return templateArgs(name: name, workbenchID: workbenchID, params: params) + ["--render", "--json"]
        case let .sessionLaunched(step, session):
            return ["automations", "session-launched", "--step", String(step), "--session", String(session), "--json"]
        case let .sessionEnded(step, status, error):
            var out = ["automations", "session-ended", "--step", String(step), "--status", status.rawValue]
            if let error, !error.isEmpty { out += ["--error", error] }
            return out + ["--json"]
        case let .rescan(workbenchID):
            // The personal folder and this workbench's (spec §13.4).
            return ["automations", "rescan", "--workbench", String(workbenchID)]
        case let .reply(outputID, action):
            return ["automations", "reply", "--output", String(outputID), "--action", String(action), "--json"]
        }
    }

    /// `install-template NAME [--workbench ID] [--param KEY=VALUE]…`, params
    /// sorted by key, empty values omitted.
    private static func templateArgs(name: String, workbenchID: Int64?, params: [String: String]) -> [String] {
        var out = ["automations", "install-template", name]
        if let workbenchID { out += ["--workbench", String(workbenchID)] }
        for key in params.keys.sorted() {
            guard let value = params[key], !value.isEmpty else { continue }
            out += ["--param", "\(key)=\(value)"]
        }
        return out
    }

    /// `rerunOf` repeats one failed (or interrupted) run of `id`.
    package func run(_ id: Int64, rerunOf: Int64? = nil) async throws -> RunResult {
        try await decode(.run(id, rerunOf: rerunOf))
    }

    package func dryRun(_ id: Int64) async throws -> DryRunResult {
        try await decode(.dryRun(id))
    }

    package func show(_ id: Int64) async throws -> AutomationDetail {
        try await decode(.show(id))
    }

    package func validate(file: URL, against: Int64?, workbench: Int64? = nil) async throws -> ValidateResult {
        try await decode(.validate(file: file.path, against: against, workbench: workbench))
    }

    package func save(file: URL, path: String, confirmHash: String, expectContentHash: String) async throws
        -> SaveResult {
        try await decode(.save(file: file.path, path: path, confirmHash: confirmHash,
                               expectContentHash: expectContentHash))
    }

    package func confirm(_ id: Int64, hash: String) async throws {
        _ = try await runner.run(args: Self.args(.confirm(id, hash: hash)))
    }

    package func setEnabled(_ id: Int64, _ on: Bool) async throws {
        _ = try await runner.run(args: Self.args(.setEnabled(id, on)))
    }

    package func setAuto(_ id: Int64, tool: String, on: Bool, hash: String?) async throws {
        _ = try await runner.run(args: Self.args(.auto(id, tool: tool, on: on, hash: hash)))
    }

    package func delete(_ id: Int64) async throws {
        _ = try await runner.run(args: Self.args(.delete(id)))
    }

    package func cancel(runID: Int64) async throws {
        _ = try await runner.run(args: Self.args(.cancel(runID: runID)))
    }

    package func wake() async throws {
        _ = try await runner.run(args: Self.args(.wake))
    }

    package func templates() async throws -> [AutomationTemplate] {
        try await decode(.templates)
    }

    package func installTemplate(_ name: String, workbenchID: Int64?, params: [String: String] = [:])
        async throws -> InstallResult {
        try await decode(.installTemplate(name: name, workbenchID: workbenchID, params: params))
    }

    /// The template's recipe files rendered and validated, nothing written.
    package func renderTemplate(_ name: String, workbenchID: Int64?, params: [String: String])
        async throws -> RenderResult {
        try await decode(.renderTemplate(name: name, workbenchID: workbenchID, params: params))
    }

    /// Attaches the session the app launched to its waiting step; false when
    /// the step no longer waits for one (nothing attached).
    package func sessionLaunched(step: Int64, session: Int64) async throws -> Bool {
        let result: Attached = try await decode(.sessionLaunched(step: step, session: session))
        return result.attached
    }

    /// Reports a step's session ended (or never launched); false when the
    /// step no longer waits for a session.
    package func sessionEnded(step: Int64, status: SessionEnd, error: String?) async throws -> Bool {
        let result: Ended = try await decode(.sessionEnded(step: step, status: status, error: error))
        return result.ended
    }

    /// Indexes the personal folder and workbench `workbenchID`'s (a protected
    /// folder the daemon never reads, spec §13.4).
    package func rescan(workbenchID: Int64) async throws {
        _ = try await runner.run(args: Self.args(.rescan(workbenchID: workbenchID)))
    }

    /// Records the press of a card's Reply action and queues one
    /// `trigger='reply'` run (AUTO-09); the CLI wakes the daemon itself.
    package func reply(outputID: Int64, action: Int) async throws -> ReplyResult {
        try await decode(.reply(outputID: outputID, action: action))
    }

    private func decode<T: Decodable>(_ op: Op) async throws -> T {
        let data = try await runner.run(args: Self.args(op))
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Results

extension AutomationsCLI {
    /// `session-launched --json` / `session-ended --json`: `{attached}` / `{ended}`.
    private struct Attached: Decodable { let attached: Bool }
    private struct Ended: Decodable { let ended: Bool }

    /// `run --json`.
    package struct RunResult: Decodable, Equatable, Sendable {
        package let runID: Int64
        package let coalesced: Bool
        package let daemonRunning: Bool

        enum CodingKeys: String, CodingKey {
            case runID = "run_id", coalesced, daemonRunning = "daemon_running"
        }
    }

    /// `reply --json`.
    package struct ReplyResult: Decodable, Equatable, Sendable {
        package let runID: Int64
        package let daemonRunning: Bool

        enum CodingKeys: String, CodingKey {
            case runID = "run_id", daemonRunning = "daemon_running"
        }
    }

    /// `dry-run --json`; the steps are read from the database by `runID`.
    package struct DryRunResult: Decodable, Equatable, Sendable {
        package let runID: Int64
        package let status: String
        package let error: String
        package let inputTokens: Int64
        package let outputTokens: Int64

        enum CodingKeys: String, CodingKey {
            case runID = "run_id", status, error, inputTokens = "input_tokens", outputTokens = "output_tokens"
        }
    }

    /// `validate --json` (with `--against`, `widening` is measured from that automation).
    package struct ValidateResult: Decodable, Equatable, Sendable {
        package let ok: Bool
        package let errors: [String]
        package let slug: String
        package let name: String
        package let scope: String
        package let approvalHash: String
        package let contentHash: String
        package let permissions: [String]
        package let outputs: [String]
        package let widening: [String]
        /// Whether the validated text feeds its sources to `llm()`
        /// (`feeds_sources_to_llm`, #559); false from an older CLI.
        package let feedsSourcesToLLM: Bool
        /// Hashed fields that differ from the confirmed recipe (`changes`);
        /// `[]` from an older CLI.
        package let changes: [AutomationChange]
        /// Whether `changes` is a real comparison (`changes_known`).
        package let changesKnown: Bool
        /// The hashed fields the manifest keys do not carry (`fields`): `{}`
        /// when the text does not parse, nil from an older CLI.
        package let fields: Fields?

        /// `fields`: the trigger in one line ("schedule: 0 9 * * 1-5",
        /// "event: slack.new_messages where account=a", "button", "button
        /// (asks before running)", "manual"), `missed` ("run_once"/"skip"),
        /// the concurrency in decimal and the budget.
        package struct Fields: Decodable, Equatable, Sendable {
            package struct Budget: Decodable, Equatable, Sendable {
                package let tokens: Int
                package let minutes: Int
            }

            package let trigger: String
            package let missed: String
            package let concurrency: String
            package let budget: Budget?

            /// Every field present: what the column needs to show them all.
            package var isComplete: Bool {
                !trigger.isEmpty && !missed.isEmpty && Int(concurrency) != nil && budget != nil
            }

            package init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                trigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? ""
                missed = try c.decodeIfPresent(String.self, forKey: .missed) ?? ""
                concurrency = try c.decodeIfPresent(String.self, forKey: .concurrency) ?? ""
                budget = try c.decodeIfPresent(Budget.self, forKey: .budget)
            }

            private enum CodingKeys: String, CodingKey { case trigger, missed, concurrency, budget }
        }

        /// The validated text is `ok` and every hashed field can be shown
        /// (AUTO-06: only a screen showing every hashed field confirms).
        package var showsAllFields: Bool { ok && fields?.isComplete == true }

        enum CodingKeys: String, CodingKey {
            case ok, errors, slug, name, scope, permissions, outputs, widening, changes, fields
            case changesKnown = "changes_known"
            case approvalHash = "approval_hash", contentHash = "content_hash"
            case feedsSourcesToLLM = "feeds_sources_to_llm"
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = try c.decode(Bool.self, forKey: .ok)
            errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
            slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
            approvalHash = try c.decodeIfPresent(String.self, forKey: .approvalHash) ?? ""
            contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
            permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
            outputs = try c.decodeIfPresent([String].self, forKey: .outputs) ?? []
            widening = try c.decodeIfPresent([String].self, forKey: .widening) ?? []
            feedsSourcesToLLM = try c.decodeIfPresent(Bool.self, forKey: .feedsSourcesToLLM) ?? false
            changes = try c.decodeIfPresent([AutomationChange].self, forKey: .changes) ?? []
            changesKnown = try c.decodeIfPresent(Bool.self, forKey: .changesKnown) ?? false
            fields = try c.decodeIfPresent(Fields.self, forKey: .fields)
        }
    }

    /// `save --json`.
    package struct SaveResult: Decodable, Equatable, Sendable {
        package let automationID: Int64
        package let path: String
        package let approvalHash: String
        package let confirmed: Bool

        enum CodingKeys: String, CodingKey {
            case automationID = "automation_id", path, approvalHash = "approval_hash", confirmed
        }
    }

    /// `install-template --json` (P6's contract, plan Task 13).
    package struct InstallResult: Decodable, Equatable, Sendable {
        package let automationID: Int64
        package let path: String
        /// Each param's values as installed, given or chosen by the CLI
        /// (#582); empty from an older CLI.
        package let params: [String: [String]]
        /// The installed copies with their approval hashes; `[]` from an older CLI.
        package let installed: [InstalledRecipe]

        enum CodingKeys: String, CodingKey {
            case automationID = "automation_id", path, params, installed
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            automationID = try c.decode(Int64.self, forKey: .automationID)
            path = try c.decode(String.self, forKey: .path)
            params = try c.decodeIfPresent([String: [String]].self, forKey: .params) ?? [:]
            installed = try c.decodeIfPresent([InstalledRecipe].self, forKey: .installed) ?? []
        }
    }

    /// One installed copy in `install-template --json` `installed`.
    package struct InstalledRecipe: Decodable, Equatable, Sendable {
        package let automationID: Int64
        package let slug: String
        package let path: String
        package let parseError: String
        package let approvalHash: String

        enum CodingKeys: String, CodingKey {
            case automationID = "automation_id", slug, path
            case parseError = "parse_error", approvalHash = "approval_hash"
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            automationID = try c.decode(Int64.self, forKey: .automationID)
            slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            parseError = try c.decodeIfPresent(String.self, forKey: .parseError) ?? ""
            approvalHash = try c.decodeIfPresent(String.self, forKey: .approvalHash) ?? ""
        }
    }

    /// `install-template --render --json`: nothing is written.
    package struct RenderResult: Decodable, Equatable, Sendable {
        package let name: String
        package let scope: String
        package let params: [String: [String]]
        package let files: [RenderedFile]

        enum CodingKeys: String, CodingKey { case name, scope, params, files }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
            params = try c.decodeIfPresent([String: [String]].self, forKey: .params) ?? [:]
            files = try c.decodeIfPresent([RenderedFile].self, forKey: .files) ?? []
        }
    }

    /// One rendered recipe file with its validation.
    package struct RenderedFile: Decodable, Equatable, Sendable {
        package let slug: String
        package let text: String
        package let validate: ValidateResult
    }
}

/// One hashed field that differs from the confirmed recipe (`show --json`
/// `changes`); `old`/`new` are always strings.
package struct AutomationChange: Decodable, Equatable, Sendable {
    package let field: String
    package let old: String
    package let new: String

    package init(field: String, old: String, new: String) {
        self.field = field
        self.old = old
        self.new = new
    }
}

/// One write tool the recipe's manifest admits (`show --json` `auto_tools`):
/// the edit form's Auto toggle, or an "Always asks" row when `alwaysAsks`;
/// `external` marks a write outside Watchtower (#559, false from an older CLI).
package struct AutomationAutoTool: Decodable, Equatable, Sendable {
    package let tool: String
    package let alwaysAsks: Bool
    package let external: Bool

    package init(tool: String, alwaysAsks: Bool, external: Bool = false) {
        self.tool = tool
        self.alwaysAsks = alwaysAsks
        self.external = external
    }

    enum CodingKeys: String, CodingKey {
        case tool, external, alwaysAsks = "always_asks"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decode(String.self, forKey: .tool)
        alwaysAsks = try c.decode(Bool.self, forKey: .alwaysAsks)
        external = try c.decodeIfPresent(Bool.self, forKey: .external) ?? false
    }
}

/// `show --json`. P2's `grants` key is not decoded: grants are read from
/// `automation_tool_grants` (spec §9.4).
package struct AutomationDetail: Decodable, Equatable, Sendable {
    package let id: Int64
    package let slug: String
    package let scope: String
    package let projectID: Int64
    package let path: String
    package let name: String
    package let description: String
    package let script: String
    package let recipeText: String
    package let triggerKind: String
    package let triggerSpec: String
    package let permissions: [String]
    package let outputs: [String]
    package let budgetTokens: Int
    package let budgetMinutes: Int
    package let concurrency: Int
    package let missedPolicy: String
    package let pauseTimeoutHours: Int
    package let enabled: Bool
    package let runnable: Bool
    package let needsConfirmation: Bool
    package let parseError: String
    package let contentHash: String
    package let approvalHash: String
    package let confirmedHash: String
    package let widening: [String]
    package let changes: [AutomationChange]
    package let changesKnown: Bool
    package let changedBy: String
    package let changedAt: Date?
    package let autoTools: [AutomationAutoTool]
    /// External tools with an auto grant (active or paused) of a recipe that
    /// feeds its sources to `llm()` (`llm_auto_writes`, #559): the
    /// confirmation sheet warns about them. `[]` from an older CLI.
    package let llmAutoWrites: [String]
    /// Whether the indexed recipe feeds its sources to `llm()`
    /// (`feeds_sources_to_llm`, #559): the edit form's Auto warning.
    package let feedsSourcesToLLM: Bool

    enum CodingKeys: String, CodingKey {
        case id, slug, scope, path, name, description, script, permissions, outputs, concurrency, enabled
        case runnable, widening, changes
        case projectID = "project_id", recipeText = "recipe_text", triggerKind = "trigger_kind"
        case triggerSpec = "trigger_spec", budgetTokens = "budget_tokens", budgetMinutes = "budget_minutes"
        case missedPolicy = "missed_policy", pauseTimeoutHours = "pause_timeout_hours"
        case needsConfirmation = "needs_confirmation", parseError = "parse_error", contentHash = "content_hash"
        case approvalHash = "approval_hash", confirmedHash = "confirmed_hash", changesKnown = "changes_known"
        case changedBy = "changed_by", changedAt = "changed_at", autoTools = "auto_tools"
        case llmAutoWrites = "llm_auto_writes", feedsSourcesToLLM = "feeds_sources_to_llm"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        slug = try c.decode(String.self, forKey: .slug)
        scope = try c.decode(String.self, forKey: .scope)
        projectID = try c.decodeIfPresent(Int64.self, forKey: .projectID) ?? 0
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        recipeText = try c.decodeIfPresent(String.self, forKey: .recipeText) ?? ""
        triggerKind = try c.decodeIfPresent(String.self, forKey: .triggerKind) ?? ""
        triggerSpec = try c.decodeIfPresent(String.self, forKey: .triggerSpec) ?? "{}"
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        outputs = try c.decodeIfPresent([String].self, forKey: .outputs) ?? []
        budgetTokens = try c.decodeIfPresent(Int.self, forKey: .budgetTokens) ?? 0
        budgetMinutes = try c.decodeIfPresent(Int.self, forKey: .budgetMinutes) ?? 0
        concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? 1
        missedPolicy = try c.decodeIfPresent(String.self, forKey: .missedPolicy) ?? ""
        pauseTimeoutHours = try c.decodeIfPresent(Int.self, forKey: .pauseTimeoutHours) ?? 0
        enabled = try c.decode(Bool.self, forKey: .enabled)
        runnable = try c.decode(Bool.self, forKey: .runnable)
        needsConfirmation = try c.decode(Bool.self, forKey: .needsConfirmation)
        parseError = try c.decodeIfPresent(String.self, forKey: .parseError) ?? ""
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
        approvalHash = try c.decodeIfPresent(String.self, forKey: .approvalHash) ?? ""
        confirmedHash = try c.decodeIfPresent(String.self, forKey: .confirmedHash) ?? ""
        widening = try c.decodeIfPresent([String].self, forKey: .widening) ?? []
        changes = try c.decodeIfPresent([AutomationChange].self, forKey: .changes) ?? []
        changesKnown = try c.decodeIfPresent(Bool.self, forKey: .changesKnown) ?? false
        changedBy = try c.decodeIfPresent(String.self, forKey: .changedBy) ?? ""
        autoTools = try c.decodeIfPresent([AutomationAutoTool].self, forKey: .autoTools) ?? []
        llmAutoWrites = try c.decodeIfPresent([String].self, forKey: .llmAutoWrites) ?? []
        feedsSourcesToLLM = try c.decodeIfPresent(Bool.self, forKey: .feedsSourcesToLLM) ?? false
        if let text = try c.decodeIfPresent(String.self, forKey: .changedAt) {
            guard let date = AutomationDates.parse(text) else {
                throw DecodingError.dataCorruptedError(forKey: .changedAt, in: c,
                                                       debugDescription: "changed_at is not RFC 3339: \(text)")
            }
            changedAt = date
        } else {
            changedAt = nil
        }
    }
}
