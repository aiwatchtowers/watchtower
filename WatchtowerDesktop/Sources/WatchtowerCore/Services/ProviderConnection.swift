import Foundation
import Observation

/// App-owned connection operation. Metadata never opens an auth home, keyring,
/// CLI or network connection. Only the explicit, warned test sends a prompt.
@MainActor
@Observable
package final class ProviderConnection {
    package struct Selection: Equatable, Sendable {
        package var provider: String
        package var model: String
        package var path: String
        package var serverURL: String?
        package var lightModel: String?
        package var configPath: String
        package init(provider: String, model: String, path: String, configPath: String, serverURL: String? = nil, lightModel: String? = nil) {
            self.serverURL = serverURL; self.lightModel = lightModel
            self.provider = provider; self.model = model; self.path = path; self.configPath = configPath
        }
    }
    package struct Result: Decodable {
        package var ok: Bool
        package var provider: String
        package var model: String
        package var error: String?
        package var errorCode: String?
        enum CodingKeys: String, CodingKey {
            case ok, provider, model, error
            case errorCode = "error_code"
        }
    }
    package enum Metadata: Equatable { case missingCLI, missingSignIn, notVerified, networkError }
    package private(set) var selection: Selection?
    package private(set) var state: ProviderFallbackPreview.State = .empty
    package private(set) var testing = false
    private enum OperationKind { case metadata, test }
    private var kind: OperationKind?
    package private(set) var result: String?
    private var operation = 0
    private var tasks: [Int: Task<Void, Never>] = [:]
    private let metadata: (Selection) async throws -> Metadata
    private let test: (Selection) async throws -> Result

    package init(
        metadata: @escaping (Selection) async throws -> Metadata = { selected in
            if selected.provider == "ollama" { return .notVerified }
            return try ProviderExecutableMetadata.check(provider: selected.provider, override: selected.path)
        },
        test: @escaping (Selection) async throws -> Result = { selected in
            if selected.provider == "ollama" { return try await ProviderConnection.testLocal(selected) }
            guard let runner = ProcessCLIRunner.makeDefault() else { throw CLIRunnerError.binaryNotFound }
            let data = try await runner.run(args: ProviderConnection.arguments(selected), timeout: 55)
            return try JSONDecoder().decode(Result.self, from: data)
        }
    ) { self.metadata = metadata; self.test = test }

    private static func testLocal(_ selected: Selection) async throws -> Result {
        let base = selected.serverURL?.isEmpty == false ? (selected.serverURL ?? "") : ProviderSettingsCopy.defaultOllamaURL
        let endpoint = base.hasSuffix("/") ? base + "v1/chat/completions" : base + "/v1/chat/completions"
        guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme ?? "") else { throw URLError(.badURL) }
        var results: [(model: String, error: String?)] = []
        for model in ConnectionTest.models(light: selected.lightModel, strong: selected.model) {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "messages": [["role": "user", "content": "respond with: OK"]], "stream": false
            ])
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            results.append((model, code == 200 ? nil : "HTTP \(code)"))
        }
        let summary = ConnectionTest.summary(results)
        return Result(ok: summary.success, provider: selected.provider, model: selected.model,
                      error: summary.success ? nil : summary.message)
    }

    package static func arguments(_ selection: Selection) -> [String] {
        var args = ["--config", selection.configPath, "--provider", selection.provider,
                    "ai", "test", "--model", selection.model]
        if !selection.path.isEmpty { args += ["--cli-path", selection.path] }
        return args
    }
    package func invalidate() {
        operation += 1
        for task in tasks.values { task.cancel() }
        kind = nil
        selection = nil; state = .empty; testing = false; result = nil
    }
    package func cancelAndWait() async {
        invalidate()
        // Each joiner retains its own snapshot. Completion prunes handles;
        // one quit caller must never take them away from another joiner.
        while !tasks.isEmpty {
            let draining = Array(tasks.values)
            for task in draining { task.cancel() }
            for task in draining { await task.value }
        }
    }
    package func check(_ selected: Selection, policy: ManagedPolicy) async {
        invalidate(); selection = selected; kind = .metadata
        if let refusal = ConnectionTest.policyRefusal(provider: selected.provider, policy: policy) {
            state = .policy; result = refusal; return
        }
        state = .checking
        let current = operation
        let running = track { [self] in
            do {
                let value = try await metadata(selected)
                guard operation == current else { return }
                switch value {
                case .missingCLI: state = .notInstalled
                case .missingSignIn: state = .connectionError
                case .notVerified: state = .notVerified
                case .networkError: state = .connectionNetworkError
                }
            } catch {
                guard operation == current else { return }
                state = .connectionNetworkError; result = Self.metadataFailure
            }
        }
        await running.value
    }

    private var actionKind: OperationKind? {
        guard selection != nil, ![.empty, .checking, .ready, .policy].contains(state) else { return nil }
        return kind == .test || state == .notVerified ? .test : .metadata
    }
    package func performAction(policy: ManagedPolicy) async {
        guard let selection, let actionKind else { return }
        switch actionKind {
        case .test: startTest(selection, policy: policy)
        case .metadata: await check(selection, policy: policy)
        }
    }

    /// Retain canceled/replaced operations until their asynchronous cleanup
    /// finishes. Removing only on completion also keeps concurrent joins safe.
    @discardableResult
    private func track(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        let identifier = operation
        let running = Task {
            defer { tasks.removeValue(forKey: identifier) }
            await work()
        }
        tasks[identifier] = running
        return running
    }
    package func startTest(_ selected: Selection, policy: ManagedPolicy) {
        invalidate(); selection = selected; kind = .test
        if let refusal = ConnectionTest.policyRefusal(provider: selected.provider, policy: policy) {
            state = .policy; result = refusal; return
        }
        guard !selected.model.isEmpty else { state = .notVerified; result = Self.modelRequired; return }
        testing = true; state = .checking
        let current = operation
        track { [self] in
            do {
                let response = try await test(selected)
                guard operation == current, !Task.isCancelled else { return }
                testing = false
                guard response.provider == selected.provider, response.model == selected.model else {
                    state = .connectionNetworkError; result = Self.mismatchedResult; return
                }
                switch response.errorCode {
                case "auth": state = .connectionError
                case "transport", "timeout": state = .connectionNetworkError
                case "policy": state = .policy
                default: state = response.ok ? .ready : .notVerified
                }
                result = response.ok ? "\(Self.name(selected.provider)) answered using \(response.model)."
                    : Self.testFailure + (response.error.map { " " + $0 } ?? "")
            } catch {
                guard operation == current, !Task.isCancelled else { return }
                testing = false; state = .connectionNetworkError; result = Self.testFailure
            }
        }
    }
    package static let cancelLabel = "Cancel test"
    package static let checkLabel = "Check connection"
    package static let testLabel = "Test connection"
    package static let testingLabel = "Testing connection…"
    package static let localWarning = "Test connection sends one short request per distinct light and strong model to the selected server. "
        + "It may use paid quota."
    package static let warning = "Test connection sends one short AI request using the selected strong model and your account. "
        + "It may use paid quota. It does not test the light model or enable reserve."
    package static let modelRequired = "Enter a strong model or wait for the model catalog before testing."
    package static let metadataFailure = "Couldn't read connection metadata. Retry the connection check."
    package static let testFailure = "Connection test failed. Retry the explicit test to send another request."
    package static let mismatchedResult = "The response didn't match the selected provider and model. Connection is not verified."
    package static func name(_ id: String) -> String { id == "ollama" ? "Ollama / Local" : id == "codex" ? "Codex" : "Claude" }
    package func label(for provider: String) -> String {
        let current = selection?.provider == provider ? state : .notVerified
        return ProviderFallbackPreview(preferred: .claude, state: current).connectionLabel
    }
    package var copy: ProviderFallbackPreview.Copy? {
        guard let selection else { return nil }
        let provider: ProviderFallbackPreview.Provider = selection.provider == "codex" ? .codex : .claude
        if testing {
            return .init(title: Self.testingLabel,
                         detail: selection.provider == "ollama" ? Self.localWarning : Self.warning,
                         action: nil, emphasis: .neutral, busy: true)
        }
        if state == .ready {
            return .init(title: "Connection test completed", detail: result ?? "", action: nil, emphasis: .success)
        }
        let approved = ProviderFallbackPreview(preferred: state == .policy ? provider : provider.other, state: state).copy
        let action = actionKind.map { action in
            action == .metadata ? "Retry connection check" : kind == .test ? "Retry connection test" : Self.testLabel
        }
        let detail = state == .connectionError
            ? "Sign in to the \(Self.name(selection.provider)) CLI in Terminal, then test connection again."
            : state == .checking ? "Checking the installed CLI without reading credentials or sending an AI prompt." : approved.detail
        if selection.provider == "ollama" {
            return .init(title: state == .policy ? "Ollama / Local is blocked by your organization" : "Local connection isn't verified",
                         detail: state == .policy ? approved.detail : Self.localWarning, action: action,
                         emphasis: approved.emphasis, busy: approved.busy)
        }
        return .init(title: approved.title, detail: detail, action: action, emphasis: approved.emphasis, busy: approved.busy)

    }
}
