import Observation
import os
import SwiftUI
import WatchtowerKit
import GRDB

@MainActor
@Observable
final class SettingsViewModel {
    /// Replica record counts per slice kind (rawValue → count).
    private(set) var counts: [(kind: String, count: Int)] = []
    private var cancellable: AnyDatabaseCancellable?
    // nonisolated: logged from the @Sendable observation onError closure.
    private nonisolated static let logger = Logger(subsystem: "WatchtowerMobile", category: "SettingsViewModel")

    func start(store: ReplicaStore) {
        guard cancellable == nil else { return }
        let observation = ValueObservation.tracking { db -> [(String, Int)] in
            try Row.fetchAll(db, sql: "SELECT kind, COUNT(*) AS n FROM slice_records GROUP BY kind ORDER BY kind")
                .map { ($0["kind"], $0["n"]) }
        }
        cancellable = observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { Self.logger.error("settings counts error: \($0.localizedDescription, privacy: .public)") },
            onChange: { [weak self] rows in MainActor.assumeIsolated { self?.counts = rows.map { (kind: $0.0, count: $0.1) } } }
        )
    }
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = SettingsViewModel()
    /// SecureField draft for a NEW key. Cleared on save and never refilled —
    /// the stored key must never be rendered back into the UI.
    @State private var keyDraft = ""
    /// Human-readable Keychain failure, shown inline (never the key itself).
    @State private var keyError: String?

    var body: some View {
        @Bindable var env = env
        NavigationStack {
            List {
                Section("App") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("WatchtowerKit", value: WatchtowerKitInfo.version)
                    LabeledContent("Connected transport", value: env.transportLabel)
                }
                Section {
                    if env.hasAPIKey {
                        // "Saved" placeholder state — NEVER the stored value.
                        LabeledContent("API key", value: "sk-ant-… (saved)")
                        Button("Remove key", role: .destructive, action: removeKey)
                    } else {
                        SecureField("Anthropic API key (sk-ant-…)", text: $keyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(saveKey)
                    }
                    if let keyError {
                        Text(keyError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Picker("Model", selection: $env.agentModel) {
                        ForEach(AgentModel.allCases, id: \.self) { choice in
                            Text(Self.modelLabel(choice)).tag(choice)
                        }
                    }
                } header: {
                    Text("Offline agent")
                } footer: {
                    Text(
                        """
                        Your Anthropic API key is used only when your Mac is unreachable, \
                        and only after you confirm per conversation. It stays in the \
                        device Keychain.
                        """
                    )
                }
                Section("Replica records") {
                    if model.counts.isEmpty {
                        Text("No records").foregroundStyle(.secondary)
                    }
                    ForEach(model.counts, id: \.kind) { row in
                        LabeledContent(row.kind, value: "\(row.count)")
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .onAppear { model.start(store: env.store) }
    }

    /// Saves the drafted key on SecureField commit; the draft is cleared so
    /// the secret leaves view state the moment it reaches the Keychain.
    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try env.saveAPIKey(trimmed)
            keyDraft = ""
            keyError = nil
        } catch {
            keyError = "Could not save the key to the Keychain. Try again."
        }
    }

    private func removeKey() {
        do {
            try env.removeAPIKey()
            keyError = nil
        } catch {
            keyError = "Could not remove the key from the Keychain. Try again."
        }
    }

    /// Settings-facing labels (recommendation-first, not raw model names).
    private static func modelLabel(_ model: AgentModel) -> String {
        switch model {
        case .sonnet5: "Sonnet (recommended)"
        case .opus48: "Opus (most capable)"
        case .haiku45: "Haiku (fastest)"
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
