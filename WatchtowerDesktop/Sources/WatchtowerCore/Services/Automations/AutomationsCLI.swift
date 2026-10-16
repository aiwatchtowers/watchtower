import Foundation

/// The Desktop's write path for automations: every write but an inbox
/// output's read/dismiss marks goes through `watchtower automations …`
/// (spec §9.6). Result structs decode the pinned `--json` keys of
/// cmd/automations*.go; arrays default to `[]` and unknown keys are ignored.
/// A non-zero exit surfaces as the runner's `CLIRunnerError.nonZeroExit`
/// carrying the CLI's stderr.
package struct AutomationsCLI {
    // swiftlint:disable:next type_name
    package enum Op: Equatable, Sendable {
        case run(Int64)
        case dryRun(Int64)
        case show(Int64)
        case validate(file: String, against: Int64?)
        case save(file: String, path: String, confirmHash: String, expectContentHash: String)
        case confirm(Int64, hash: String)
        case setEnabled(Int64, Bool)
        case auto(Int64, tool: String, on: Bool, hash: String?)
        case delete(Int64)
        case cancel(runID: Int64)
        case wake
        case templates
        case installTemplate(name: String, workbenchID: Int64?)
    }

    private let runner: any CLIRunnerProtocol

    package init(runner: any CLIRunnerProtocol) {
        self.runner = runner
    }

    // swiftlint:disable:next cyclomatic_complexity
    package static func args(_ op: Op) -> [String] {
        switch op {
        case let .run(id):
            return ["automations", "run", String(id), "--json"]
        case let .dryRun(id):
            return ["automations", "dry-run", String(id), "--json"]
        case let .show(id):
            return ["automations", "show", String(id), "--json"]
        case let .validate(file, against):
            var out = ["automations", "validate", file]
            if let against { out += ["--against", String(against)] }
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
        case let .installTemplate(name, workbenchID):
            var out = ["automations", "install-template", name]
            if let workbenchID { out += ["--workbench", String(workbenchID)] }
            return out + ["--json"]
        }
    }

    package func run(_ id: Int64) async throws -> RunResult {
        try await decode(.run(id))
    }

    package func dryRun(_ id: Int64) async throws -> DryRunResult {
        try await decode(.dryRun(id))
    }

    package func show(_ id: Int64) async throws -> AutomationDetail {
        try await decode(.show(id))
    }

    package func validate(file: URL, against: Int64?) async throws -> ValidateResult {
        try await decode(.validate(file: file.path, against: against))
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

    package func installTemplate(_ name: String, workbenchID: Int64?) async throws -> InstallResult {
        try await decode(.installTemplate(name: name, workbenchID: workbenchID))
    }

    private func decode<T: Decodable>(_ op: Op) async throws -> T {
        let data = try await runner.run(args: Self.args(op))
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Results

extension AutomationsCLI {
    /// `run --json`.
    package struct RunResult: Decodable, Equatable, Sendable {
        package let runID: Int64
        package let coalesced: Bool
        package let daemonRunning: Bool

        enum CodingKeys: String, CodingKey {
            case runID = "run_id", coalesced, daemonRunning = "daemon_running"
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

        enum CodingKeys: String, CodingKey {
            case ok, errors, slug, name, scope, permissions, outputs, widening
            case approvalHash = "approval_hash", contentHash = "content_hash"
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

        enum CodingKeys: String, CodingKey {
            case automationID = "automation_id", path
        }
    }
}

/// One hashed field that differs from the confirmed recipe (`show --json`
/// `changes`); `old`/`new` are always strings.
package struct AutomationChange: Decodable, Equatable, Sendable {
    package let field: String
    package let old: String
    package let new: String
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

    enum CodingKeys: String, CodingKey {
        case id, slug, scope, path, name, description, script, permissions, outputs, concurrency, enabled
        case runnable, widening, changes
        case projectID = "project_id", recipeText = "recipe_text", triggerKind = "trigger_kind"
        case triggerSpec = "trigger_spec", budgetTokens = "budget_tokens", budgetMinutes = "budget_minutes"
        case missedPolicy = "missed_policy", pauseTimeoutHours = "pause_timeout_hours"
        case needsConfirmation = "needs_confirmation", parseError = "parse_error", contentHash = "content_hash"
        case approvalHash = "approval_hash", confirmedHash = "confirmed_hash", changesKnown = "changes_known"
        case changedBy = "changed_by", changedAt = "changed_at"
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
