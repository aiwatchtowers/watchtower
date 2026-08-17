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
    /// "Connected accounts" rows grouped by service, in `AccountService`
    /// order; services with no accounts are absent. Empty ⇒ the section is
    /// hidden entirely — an older desktop that does not publish account
    /// slices renders this screen exactly as before.
    private(set) var accountSections: [(service: AccountService, rows: [AccountRow])] = []
    private var cancellable: AnyDatabaseCancellable?
    private var accountsCancellable: AnyDatabaseCancellable?
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
        // One observation spanning all three account kinds — a single
        // consistent snapshot, so a hydrate that rewrites two services can
        // never render a frame mixing old and new. Reads go through the
        // from-db `fetchAll` overload on the closure's own `db` (the
        // ReplicaObserver pool-reentrancy rule).
        let accountsObservation = ValueObservation.tracking { db -> [(AccountService, [ConnectedAccount])] in
            try AccountService.allCases.compactMap { service in
                let accounts = try store.fetchAll(ConnectedAccount.self, kind: service.kind, from: db)
                guard !accounts.isEmpty else { return nil }
                // Desktop Connections order: oldest account first (id ASC).
                return (service, accounts.sorted { $0.id < $1.id })
            }
        }
        accountsCancellable = accountsObservation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { Self.logger.error("settings accounts error: \($0.localizedDescription, privacy: .public)") },
            onChange: { [weak self] sections in
                MainActor.assumeIsolated {
                    self?.accountSections = sections.map { (service: $0.0, rows: $0.1.map(AccountRow.init)) }
                }
            }
        )
    }
}

// MARK: - Connected accounts (read-only)

/// The services whose account health the desktop publishes (`slack_account` /
/// `google_account` / `jira_account` slices). Labels and icons mirror the
/// desktop's `ConnectionService`.
enum AccountService: String, CaseIterable, Hashable {
    case slack, google, jira

    var label: String {
        switch self {
        case .slack: "Slack"
        case .google: "Google"
        case .jira: "Jira"
        }
    }

    var icon: String {
        switch self {
        case .slack: "number"
        case .google: "g.circle"
        case .jira: "checklist"
        }
    }

    var kind: SliceKind {
        switch self {
        case .slack: .slackAccount
        case .google: .googleAccount
        case .jira: .jiraAccount
        }
    }
}

/// One "Connected accounts" row — a pure presentation projection of
/// `ConnectedAccount`, READ-ONLY by owner decision (OAuth flows cannot run
/// on the phone; the desktop stays the only place accounts are managed).
struct AccountRow: Identifiable, Equatable {
    /// Badge semantics mirroring the desktop Connections tab
    /// (`slackAccountStatusColor` and friends): green ok, red revoked,
    /// orange any other non-ok. `disabled` is gray — the desktop rolls a
    /// disabled account into NEITHER ok nor problem
    /// (`ConnectionStatusLogic.enabledFilteredStatus`), because its status
    /// is not actively verified while it isn't syncing.
    enum Health: Equatable {
        case ok, disabled, revoked, attention

        var color: Color {
            switch self {
            case .ok: .green
            case .disabled: .gray
            case .revoked: .red
            case .attention: .orange
            }
        }
    }

    let id: Int
    let name: String
    let detail: String?
    let health: Health
    /// Shown for every non-ok row: the desktop's tooltip rule — the `error`
    /// text when there is one, the raw status word otherwise.
    let statusText: String

    init(_ account: ConnectedAccount) {
        id = account.id
        name = account.displayName
        detail = account.detail
        if !account.enabled {
            health = .disabled
        } else if account.isOK {
            health = .ok
        } else if account.isRevoked {
            health = .revoked
        } else {
            health = .attention
        }
        switch health {
        case .ok:
            statusText = "Connected"
        case .disabled:
            statusText = "Disabled on your Mac"
        case .revoked, .attention:
            statusText = account.error.isEmpty ? account.status : account.error
        }
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
                    LabeledContent("Sync", value: Self.syncValue(for: env.transportKind))
                    LabeledContent("Notifications", value: Self.notificationsValue(for: env.notifications.permission))
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
                // Read-only mirror of the desktop's Connections tab. Hidden
                // entirely when no account slices exist (older desktop).
                if !model.accountSections.isEmpty {
                    Section {
                        ForEach(model.accountSections, id: \.service) { section in
                            ForEach(section.rows) { row in
                                AccountRowView(service: section.service, row: row)
                            }
                        }
                    } header: {
                        Text("Connected accounts")
                    } footer: {
                        Text("Accounts are managed on your Mac.")
                    }
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
        // Re-read the system authorization on each visit — the user can flip
        // it in iOS Settings behind the app's back. Never prompts.
        .task { await env.notifications.refreshPermission() }
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

    /// Display value for the "Sync" row — which transport this install runs
    /// on ("iCloud" for entitled builds, "Demo" for unsigned sim/CI builds).
    static func syncValue(for kind: TransportKind) -> String {
        switch kind {
        case .cloudKit: "iCloud"
        case .inMemoryDemo: "Demo"
        }
    }

    /// Display value for the "Notifications" row — the remembered permission
    /// state (Decision 5: asked contextually, decline remembered).
    static func notificationsValue(for permission: NotificationPermission) -> String {
        switch permission {
        case .notAsked: "Not requested"
        case .authorized: "Allowed"
        case .denied: "Denied"
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

/// One connected account: service icon, name (+ identity detail), status dot.
/// Non-ok rows also carry the status text — the phone has no hover, so the
/// desktop's tooltip becomes an inline caption.
struct AccountRowView: View {
    let service: AccountService
    let row: AccountRow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: service.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityLabel(service.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if row.health != .ok {
                    Text(row.statusText)
                        .font(.caption)
                        .foregroundStyle(row.health == .disabled ? Color.secondary : row.health.color)
                }
            }
            Spacer()
            Circle()
                .fill(row.health.color)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
    }
}
