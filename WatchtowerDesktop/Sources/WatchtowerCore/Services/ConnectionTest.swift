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
}
