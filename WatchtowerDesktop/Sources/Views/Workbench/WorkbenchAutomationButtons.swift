import SwiftUI
import WatchtowerCore

/// The workbench's `trigger.button` automations as one ⚡ menu in its header
/// (spec §12.4), plus **New Automation…**. What a click does is
/// `WorkbenchAutomationButtonsModel`'s; a runnable click only queues a run
/// (AUTO-09). Built by the
/// page from `AppState` (its view model, the run opener),
/// so the header needs no `AppState` in the environment.
struct WorkbenchAutomationsMenu: View {
    let project: Workbench
    let vm: AutomationsViewModel
    /// Opens an automation's card, with one run open when given.
    let openRun: (_ automationID: Int64, _ runID: Int64?) -> Void
    /// **New Automation…** (nil: the item is left out).
    var onNewAutomation: (() -> Void)?
    /// The `confirm: true` button whose "Run <label>?" is up.
    @State private var confirming: AutomationHeaderButton?
    /// A failed run call: its label and the CLI's stderr.
    @State private var failure: (label: String, message: String)?

    var body: some View {
        let buttons = vm.headerButtons(projectID: project.id)
        Group {
            if !buttons.isEmpty || onNewAutomation != nil {
                Menu {
                    ForEach(buttons) { button in
                        Button(WorkbenchAutomationButtonsModel.menuTitle(for: button)) {
                            click(WorkbenchAutomationButtonsModel.action(for: button), on: button, vm: vm)
                        }
                        .disabled(vm.busy[button.automationID] != nil)
                    }
                    if let onNewAutomation {
                        if !buttons.isEmpty { Divider() }
                        Button("New Automation…", action: onNewAutomation)
                    }
                } label: {
                    if WorkbenchAutomationButtonsModel.isAnyActive(buttons, busy: Set(vm.busy.keys)) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "bolt")
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.kitIcon(isOn: false))
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Automations of this workbench")
            }
        }
        // The poll is slow off the Automations tab: opening a workbench
        // reads now, so a new recipe or a finished run shows at once.
        .onAppear { vm.refresh() }
        .alert(
            WorkbenchAutomationButtonsModel.confirmTitle(label: confirming?.label ?? ""),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { button in
            Button("Run") { click(.run, on: button, vm: vm) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Could not run \(failure?.label ?? "the automation")",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { dismissFailure(vm) } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure?.message ?? "")
        }
    }

    /// The alert showed `vm.lastError`; dismissing it clears it, so the
    /// Automations tab does not show the same failure again.
    private func dismissFailure(_ vm: AutomationsViewModel) {
        failure = nil
        vm.lastError = nil
    }

    private func click(
        _ action: WorkbenchAutomationButtonsModel.Action,
        on button: AutomationHeaderButton,
        vm: AutomationsViewModel
    ) {
        if case .confirmThenRun = action {
            confirming = button
            return
        }
        Task {
            let ok = await WorkbenchAutomationButtonsModel.perform(action, on: button, vm: vm, open: openRun)
            if !ok { failure = (button.label, vm.lastError ?? "The automation did not start.") }
        }
    }
}
