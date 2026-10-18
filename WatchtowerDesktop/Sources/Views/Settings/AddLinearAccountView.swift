import SwiftUI
import WatchtowerCore

/// Sheet for connecting a Linear workspace, from Settings → Linear and
/// onboarding's Connect step. Two ways in: Linear's browser sign-in
/// (`linear add --app-return`) or a personal API key, typed into a secure
/// field and handed to `linear add --api-key` on stdin. Closes itself once
/// the workspace is connected; teams are picked in Settings after the first
/// sync has fetched them.
struct AddLinearAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// `.deferred` from onboarding: the connect must not restart the daemon
    /// mid-setup. Settings keeps the default.
    let daemonPolicy: DaemonRestartPolicy

    init(daemonPolicy: DaemonRestartPolicy = .restart) {
        self.daemonPolicy = daemonPolicy
    }

    enum Method: String, CaseIterable, Identifiable {
        case oauth, apiKey
        var id: String { rawValue }
        var title: String {
            switch self {
            case .oauth: "Sign in with Linear"
            case .apiKey: "API key"
            }
        }
    }

    @State private var method: Method = .oauth
    @State private var apiKey = ""
    /// Set on the click, before any await, so a double click starts one connect.
    @State private var starting = false

    private var vm: LinearAccountsViewModel? { appState.linearAccountsViewModel }
    private var busy: Bool { vm?.isBusy == true || starting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Linear Workspace")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                if !busy {
                    Button("Close") { dismiss() }
                        .buttonStyle(.plain)
                }
            }

            Picker("Connect with", selection: $method) {
                ForEach(Method.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(busy)

            switch method {
            case .oauth:
                Text("""
                    Opens Linear's authorization page in your browser. After you approve, \
                    the workspace is added and its teams start syncing.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .apiKey:
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("lin_api_…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy)
                    Text("""
                        Create a personal API key in Linear under Settings → Account → Security & access. \
                        It acts with your own permissions. To revoke it later, delete it in Linear.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = vm?.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Connecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if method == .oauth {
                        Button("Cancel") { vm?.cancelConnect() }
                    }
                } else {
                    Spacer()
                    Button("Connect") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(vm == nil || (method == .apiKey && apiKey.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 300)
        // No browser sign-in outlives its sheet.
        .onDisappear { if method == .oauth, vm?.isBusy == true { vm?.cancelConnect() } }
    }

    private func connect() {
        guard let vm, !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            let countBefore = vm.accounts.count
            switch method {
            case .oauth:
                await vm.addWithOAuth(daemonPolicy: daemonPolicy)
                if vm.error == nil, vm.accounts.count > countBefore { dismiss() }
            case .apiKey:
                if await vm.addWithAPIKey(apiKey, daemonPolicy: daemonPolicy) {
                    apiKey = ""
                    dismiss()
                }
            }
        }
    }
}
