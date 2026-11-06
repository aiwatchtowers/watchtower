@MainActor
package enum ProviderSettingsCopy {
    package static let light = "Light model"
    package static let strong = "Strong model"
    package static let defaultModel = "Provider default"
    package static let workers = "Workers"
    package static let server = "Server URL"
    package static let defaultOllamaURL = "http://localhost:11434"
    package static let localExplanation = "Any OpenAI-compatible server: Ollama, LM Studio, vLLM. Reserve is unavailable for local providers."
    package static let autoDetect = "Auto-detect"
    package static func path(_ id: String) -> String { ProviderConnection.name(id) + " CLI path" }
    package static func provider(_ id: String, allowed: Bool) -> String {
        (id == "ollama" ? "Ollama / Local" : ProviderConnection.name(id)) + (allowed ? "" : " (not allowed)")
    }
    package static func catalogError(_ error: String) -> String { "Model list unavailable: " + error }
}
