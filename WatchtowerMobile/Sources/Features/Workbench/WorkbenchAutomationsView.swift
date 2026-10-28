import SwiftUI
import WatchtowerKit

/// The Workbench tab's Automations segment (ask #692): the workbench's
/// automations with Run. Running is all the phone does; a `confirm: true`
/// recipe asks first.
struct WorkbenchAutomationsView: View {
    @Environment(AppEnvironment.self) private var env
    let replica: WorkbenchReplicaModel
    let writer: BoardWriter
    let workbenchID: Int64
    let now: Date
    @State private var confirming: WorkbenchAutomation?
    @State private var sendError: String?

    var body: some View {
        let model = WorkbenchAutomationsModel(
            workbenchID: workbenchID, snapshot: replica.snapshot,
            grant: replica.snapshot.grant(for: env.linkedDevice?.deviceID), inFlight: writer.inFlight, now: now
        )
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.regular) {
                if let notAllowed = model.notAllowed {
                    Text(notAllowed).font(.footnote).foregroundStyle(.secondary)
                }
                if let sendError {
                    Text(sendError).font(.footnote).foregroundStyle(.red)
                }
                VStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { CardRowDivider() }
                        AutomationRow(row: row, run: { tap(row.automation) }, dismiss: { dismiss($0) })
                    }
                }
                .card(padding: EdgeInsets(top: Spacing.tight, leading: Spacing.medium, bottom: Spacing.tight, trailing: Spacing.medium))
                Text(AutomationRunText.footer).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.large)
        }
        .background(Color(.systemBackground))
        .confirmationDialog(
            confirming.map { AutomationRunText.confirmTitle($0.name) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { automation in
            Button(AutomationRunText.run) { send(automation) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func tap(_ automation: WorkbenchAutomation) {
        if automation.asksFirst {
            confirming = automation
        } else {
            send(automation)
        }
    }

    private func send(_ automation: WorkbenchAutomation) {
        Task {
            do {
                sendError = nil
                try await writer.runAutomation(automation, workbenchID: workbenchID)
            } catch {
                sendError = BoardWriteText.sendError(error)
            }
        }
    }

    private func dismiss(_ failure: WorkbenchAutomationsModel.Failure) {
        do {
            try writer.dismissRun(failure)
        } catch {
            sendError = error.localizedDescription
        }
    }
}

/// One automation: its kind and last run, and Run or why it does not run.
private struct AutomationRow: View {
    let row: WorkbenchAutomationsModel.Row
    let run: () -> Void
    let dismiss: (WorkbenchAutomationsModel.Failure) -> Void

    private static let insets = EdgeInsets(top: Spacing.regular, leading: 0, bottom: Spacing.regular, trailing: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            FlatRow(icon: row.icon, title: row.automation.name, titleLineLimit: 2, insets: Self.insets) {
                MetaLine(items: row.meta)
            } trailing: {
                trailing
            }
            if let failure = row.failure {
                HStack(alignment: .firstTextBaseline) {
                    Text(failure.message).font(.footnote).foregroundStyle(.red)
                    Spacer(minLength: Spacing.regular)
                    Button("Dismiss") { dismiss(failure) }.font(.footnote)
                }
                .padding(.bottom, Spacing.tight)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.action {
        case .run:
            Button(action: run) {
                Label(AutomationRunText.run, systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Run \(row.automation.name)")
        case let .sending(text):
            HStack(spacing: Spacing.tight) {
                ProgressView().controlSize(.small)
                Text(text).font(TypeScale.meta).foregroundStyle(.secondary)
            }
        case .running:
            Pill(text: AutomationRunText.running, tone: .blue)
        case let .unavailable(reason):
            Text(reason).font(TypeScale.meta).foregroundStyle(.tertiary)
        }
    }
}
