import Foundation

/// Pure logic behind Settings' Test Connection button: which tier models to
/// exercise and how to fold the per-model outcomes into one result line.
package enum ConnectionTest {
    /// The models one test run should exercise, tier order (light first),
    /// deduped so light == strong costs a single call. Empty/unresolved
    /// tiers drop out.
    package static func models(light: String?, strong: String?) -> [String] {
        var out: [String] = []
        for model in [light, strong] {
            guard let model, !model.isEmpty, !out.contains(model) else { continue }
            out.append(model)
        }
        return out
    }

    /// Folds per-model outcomes (error == nil means the model answered) into
    /// the single result line the row renders: all green collapses to one
    /// "Connected (...)", any failure lists only the failing models.
    package static func summary(_ results: [(model: String, error: String?)]) -> (success: Bool, message: String) {
        let failures = results.filter { $0.error != nil }
        guard failures.isEmpty else {
            let lines = failures.map { "\($0.model): \($0.error ?? "")" }
            return (false, lines.joined(separator: " · "))
        }
        return (true, "Connected (\(results.map(\.model).joined(separator: ", ")))")
    }

    // MARK: - codex exec failures

    /// Why a failed `codex exec --json` run failed, read from its stdout
    /// JSONL: codex reports the reason there (turn.failed, or a top-level
    /// error event when there is no turn.failed) and leaves stderr empty.
    /// nil when the output names no failure. Dual path with Go's
    /// `codex.failedTurn`: same wording, pinned by the shared fixture
    /// `internal/codex/testdata/turn_failures.json`.
    package static func codexTurnError(stdout: String, model: String) -> String? {
        var lastTopLevel: String?
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let event = jsonObject(String(line)) else { continue }
            if let error = event["error"] as? [String: Any] {
                return codexTurnMessage(model: model, message: error["message"] as? String ?? "")
            }
            if event["type"] as? String == "error", let message = event["message"] as? String, !message.isEmpty {
                lastTopLevel = message
            }
        }
        return lastTopLevel.map { codexTurnMessage(model: model, message: $0) }
    }

    /// One failed turn's message: a JSON envelope unwrapped to its message
    /// with its type and status kept, a model refusal named with its way out.
    private static func codexTurnMessage(model: String, message: String) -> String {
        guard let body = jsonObject(message),
              let error = body["error"] as? [String: Any],
              let inner = error["message"] as? String, !inner.isEmpty else {
            return classifyCodexTurn(model: model, message: message, tags: "")
        }
        var tags: [String] = []
        if let type = error["type"] as? String, !type.isEmpty { tags.append(type) }
        if let status = body["status"] as? Int, status != 0 { tags.append("status code \(status)") }
        return classifyCodexTurn(model: model, message: inner, tags: tags.joined(separator: ", "))
    }

    private static func classifyCodexTurn(model: String, message: String, tags: String) -> String {
        let lower = message.lowercased()
        let settings = "pick another model in Settings → System → AI"
        if lower.contains("model requires a newer version of codex") {
            return "Codex needs an update to use \(model): run `codex update`, or \(settings)"
        }
        if lower.contains("model is not supported when using codex with a chatgpt account")
            || lower.contains("does not exist or you do not have access to it") {
            return "\(model) isn't available on your Codex account: \(settings)"
        }
        return tags.isEmpty ? "codex error: \(message)" : "codex error (\(tags)): \(message)"
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
