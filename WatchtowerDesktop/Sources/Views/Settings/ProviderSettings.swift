import SwiftUI
import WatchtowerCore

/// The real form and catalog use the same status component and model copy.
struct ProviderSettings: View {
    @Bindable var config: ConfigService
    let catalog: AIModelCatalog
    let policy: ManagedPolicy

    private var preferred: String { config.aiProvider ?? "claude" }
    /// The reserve the preferred provider pairs with: the catalog's
    /// `reserve_peer` (LLMTRANSPORT-01); nil hides the reserve section.
    private var reserve: String? { config.reservePeer }
    private var connection: ProviderConnection { config.providerConnection }
    private var signature: String {
        [preferred, config.aiModelLight, config.aiModelStrong, config.claudePath, config.codexPath,
         config.aiFallbackProvider, config.aiOllamaURL, config.activeWorkspace].map { $0 ?? "" }.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            preferredSection
            if let reserve { reserveSection(reserve) }
            if preferred == "ollama" { ollamaSection }
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(ProviderSettingsCopy.workers).font(.caption).foregroundStyle(.secondary)
                TextField(ProviderSettingsCopy.workers, value: $config.aiWorkers, format: .number).textFieldStyle(.kit)
            }
            if let error = catalog.lastError {
                Text(ProviderSettingsCopy.catalogError(error)).font(.caption).foregroundStyle(Tone.warning)
            }
            // Saved quota blocks exist only for a provider that reports a
            // subscription quota (its capability row).
            if catalog.capabilities(for: preferred).quota { healthSection }
            Text(ProviderFallbackPreview.scope).font(.caption).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .onChange(of: signature) { _, _ in connection.invalidate() }
    }

    private var preferredSection: some View {
        SettingsSection(title: ProviderFallbackPreview.preferredLabel) {
            Picker(ProviderFallbackPreview.preferredLabel, selection: Binding(
                get: { preferred }, set: { config.selectPreferredProvider($0) }
            )) {
                ForEach(["claude", "codex", "ollama"].filter { policy.providerAllowed($0) || $0 == preferred }, id: \.self) { id in
                    Text(ProviderSettingsCopy.provider(id, allowed: policy.providerAllowed(id))).tag(id)
                }
            }
            .managedByOrganization(policy.allowedAIProviders == [preferred])
            Text(connection.label(for: preferred)).font(.caption).foregroundStyle(.secondary)
            models(provider: preferred, reserve: false)
            if preferred != "ollama" { pathField(preferred) }
            connectionActions(preferred)
        }
    }
    private func reserveSection(_ reserve: String) -> some View {
        SettingsSection(title: ProviderFallbackPreview.reserveLabel) {
            HStack {
                Text(ProviderConnection.name(reserve)).font(.headline)
                Spacer()
                Text(connection.label(for: reserve)).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(ProviderFallbackPreview.automaticLabel, isOn: Binding(
                get: { config.aiFallbackEnabled }, set: {
                    config.aiFallbackProvider = reserve
                    config.aiFallbackEnabled = $0
                }
            ))
            .toggleStyle(.switch)
            .disabled(!policy.providerAllowed(preferred) || !policy.providerAllowed(reserve))
            models(provider: reserve, reserve: true)
            pathField(reserve)
            connectionActions(reserve)
            Text(ProviderFallbackPreview.recovery).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var ollamaSection: some View {
        SettingsSection(title: ProviderSettingsCopy.server) {
            TextField(ProviderSettingsCopy.server, text: Binding(
                get: { config.aiOllamaURL ?? "" }, set: { config.aiOllamaURL = $0.isEmpty ? nil : $0 }
            ), prompt: Text(ProviderSettingsCopy.defaultOllamaURL))
            pathField("claude")
            Text(ProviderSettingsCopy.localExplanation).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func models(provider: String, reserve: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            modelField(ProviderSettingsCopy.light, provider: provider, tier: "light", reserve: reserve)
            modelField(ProviderSettingsCopy.strong, provider: provider, tier: "strong", reserve: reserve)
        }
    }
    private func modelField(_ title: String, provider: String, tier: String, reserve: Bool) -> some View {
        let resolved = tier == "light" ? catalog.provider(provider)?.resolvedLight : catalog.provider(provider)?.resolvedStrong
        let value = Binding<String>(get: {
            if reserve { return config.reserveModel(tier) ?? "" }
            return (tier == "light" ? config.aiModelLight : config.aiModelStrong) ?? ""
        }, set: { value in
            let model: String? = value.isEmpty ? nil : value
            if reserve {
                config.aiFallbackProvider = provider
                config.setReserveModel(tier, value: model)
            } else if tier == "light" { config.aiModelLight = model } else { config.aiModelStrong = model }
        })
        return VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(title, text: value, prompt: Text(resolved ?? ProviderSettingsCopy.defaultModel)).textFieldStyle(.kit)
                if !catalog.suggestions(for: provider).isEmpty {
                    Menu {
                        Button(ProviderSettingsCopy.defaultModel) { value.wrappedValue = "" }
                        ForEach(catalog.suggestions(for: provider), id: \.self) { model in
                            Button(model) { value.wrappedValue = model }
                        }
                    } label: { Image(systemName: "chevron.up.chevron.down") }
                    .menuStyle(.borderlessButton)
                }
            }
        }
    }
    private func pathField(_ provider: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(ProviderSettingsCopy.path(provider)).font(.caption).foregroundStyle(.secondary)
            TextField(ProviderSettingsCopy.path(provider), text: Binding(
                get: { (provider == "codex" ? config.codexPath : config.claudePath) ?? "" },
                set: { if provider == "codex" { config.codexPath = $0.isEmpty ? nil : $0 } else { config.claudePath = $0.isEmpty ? nil : $0 }
                }
            ), prompt: Text(ProviderSettingsCopy.autoDetect)).textFieldStyle(.kit)
        }
    }
    private func selection(_ provider: String) -> ProviderConnection.Selection {
        let form = provider == preferred ? config.aiModelStrong : config.reserveModel("strong")
        let model = form?.isEmpty == false ? form : catalog.provider(provider)?.resolvedStrong
        return .init(provider: provider, model: model ?? "",
                     path: (provider == "codex" ? config.codexPath : config.claudePath) ?? "",
                     configPath: config.connectionConfigPath, serverURL: config.aiOllamaURL,
                     lightModel: config.aiModelLight ?? catalog.provider(provider)?.resolvedLight)
    }
    private func connectionActions(_ provider: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(provider == "ollama" ? ProviderConnection.localWarning : ProviderConnection.warning)
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { checkButton(provider); testButton(provider) }
                VStack(alignment: .leading) { checkButton(provider); testButton(provider) }
            }
            if connection.selection?.provider == provider {
                connectionStatus
                if connection.testing {
                    Button(ProviderConnection.cancelLabel) { connection.invalidate() }.buttonStyle(.kitQuiet)
                }
            }
        }
    }
    private func checkButton(_ provider: String) -> some View {
        Button(ProviderConnection.checkLabel) { Task { await connection.check(selection(provider), policy: policy) } }
            .buttonStyle(.kitSecondary).disabled(connection.testing)
    }
    private func testButton(_ provider: String) -> some View {
        Button(ProviderConnection.testLabel) { connection.startTest(selection(provider), policy: policy) }
            .buttonStyle(.kitSecondary).disabled(connection.testing)
    }
    @ViewBuilder private var connectionStatus: some View {
        if let copy = connection.copy {
            ProviderFallbackStatus(copy: copy) {
                Task { await connection.performAction(policy: policy) }
            }
            if let result = connection.result, connection.state != .ready {
                Text(result).font(.caption).foregroundStyle(Tone.warning).textSelection(.enabled)
            }
        }
    }
    private var healthSection: some View {
        SettingsSection(title: ProviderSettingsHealth.title) {
            Text(ProviderSettingsHealth.explanation).font(.caption).foregroundStyle(.secondary)
            if let copy = config.providerHealth.copy { ProviderFallbackStatus(copy: copy) }
            Button(config.providerHealth.failed ? ProviderSettingsHealth.retry : ProviderSettingsHealth.check) {
                Task { await config.refreshProviderHealth() }
            }.buttonStyle(.kitSecondary).disabled(config.providerHealth.busy)
        }
    }
}
