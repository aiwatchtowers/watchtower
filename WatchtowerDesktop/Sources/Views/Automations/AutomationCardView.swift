import SwiftUI
import WatchtowerCore

/// The automation card (spec §12.2, approved mockup 1): title and subtitle,
/// **Run now** / **Dry run** / **Change in words** / **Edit** / **⋯**
/// (Enable/Disable, Delete), the dry-run result, the description, **It may**,
/// **Limits per run**, the latest reports and **History**. The recipe itself
/// is reached from **Edit** and the confirmation sheet, not shown here.
struct AutomationCardView: View {
    @Bindable var vm: AutomationsViewModel
    let item: AutomationListItem
    let actions: AutomationsTabActions
    let workbenchName: String?
    let now: Date

    @State private var confirmingDelete = false

    private var automation: Automation { item.automation }
    private var detail: AutomationDetail? { vm.details[automation.id] }
    private var buttons: AutomationCardPresentation.Buttons { AutomationCardPresentation.buttons(for: automation) }
    private var isBusy: Bool { vm.busy[automation.id] != nil }

    /// `show --json` is re-read when the recipe changes.
    private struct DetailKey: Hashable {
        let id: Int64
        let contentHash: String
        let approvalHash: String
        let confirmedHash: String
    }

    /// A run that becomes the newest opens once (`expandNewestRun`).
    private struct NewestRunKey: Hashable {
        let id: Int64
        let newestRunID: Int64?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                dryRunResult
                if let error = vm.detailErrors[automation.id] {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if !automation.parseError.isEmpty {
                    Text(automation.parseError)
                        .font(.callout.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let description = detail?.description, !description.isEmpty {
                    MarkdownView(text: description)
                        .frame(maxWidth: 680, alignment: .leading)
                }
                HStack(alignment: .top, spacing: 14) {
                    permissionsBox
                    limitsBox
                }
                reports
                AutomationRunHistoryView(
                    runs: vm.runs[automation.id] ?? [],
                    steps: vm.steps,
                    expanded: vm.expandedRuns,
                    canRun: buttons.runNow.enabled,
                    isBusy: isBusy,
                    now: now,
                    onToggle: { vm.toggleRun($0) },
                    onRerun: { runID in Task { await vm.rerun(automation.id, runID: runID) } },
                    onCancel: { runID in Task { await vm.cancel(runID: runID) } },
                    onOpenInbox: actions.onOpenInbox
                )
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: DetailKey(id: automation.id, contentHash: automation.contentHash,
                            approvalHash: automation.approvalHash, confirmedHash: automation.confirmedHash)) {
            await vm.loadDetail(automation.id)
        }
        .task(id: NewestRunKey(id: automation.id, newestRunID: vm.runs[automation.id]?.first?.id)) {
            vm.expandNewestRun(automation.id)
        }
        .confirmationDialog("Delete “\(automation.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                let id = automation.id
                Task { await vm.delete(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the recipe file with its runs, state and outputs.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(automation.name.isEmpty ? automation.slug : automation.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text(AutomationCardPresentation.subtitle(automation, workbenchName: workbenchName))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            buttonRow
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Button("Run now") {
                let id = automation.id
                Task { await vm.runNow(id) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!buttons.runNow.enabled || isBusy)
            .help(buttons.runNow.help ?? "")

            Button("Dry run") {
                let id = automation.id
                Task { await vm.dryRun(id) }
            }
            .disabled(!buttons.dryRun.enabled || isBusy)
            .help(buttons.dryRun.help ?? "")

            Button("Change in words") { actions.onChangeInWords?(automation.id) }
                .disabled(actions.onChangeInWords == nil)
            Button("Edit") { actions.onEdit?(automation.id) }
                .disabled(actions.onEdit == nil)

            Menu {
                Button(buttons.toggleLabel) {
                    let id = automation.id
                    let enable = !automation.enabled
                    Task { await vm.setEnabled(id, enable) }
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            } label: {
                Text("⋯")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isBusy)
            .accessibilityLabel("More actions")
        }
    }

    // MARK: - Dry run

    @ViewBuilder private var dryRunResult: some View {
        switch vm.dryRuns[automation.id] {
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Dry run…").foregroundStyle(.secondary)
            }
        case let .done(_, lines, tokens, status):
            VStack(alignment: .leading, spacing: 6) {
                Text("Dry run · nothing was written")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if lines.isEmpty {
                    Text("No steps.").foregroundStyle(.secondary)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).textSelection(.enabled)
                }
                Text("\(AutomationCardPresentation.tokensText(tokens, estimated: false)) · \(status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case nil:
            EmptyView()
        }
    }

    // MARK: - Sections

    private var permissionsBox: some View {
        let lines = AutomationCardPresentation.permissionLines(
            permissions: automation.permissions, outputs: automation.outputs, widening: detail?.widening ?? []
        )
        return sectionBox("It may") {
            if lines.isEmpty {
                Text("Nothing beyond its own state").foregroundStyle(.secondary)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.text)
                    if line.isNew {
                        Text("new since your confirmation")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var limitsBox: some View {
        sectionBox("Limits per run") {
            ForEach(AutomationCardPresentation.limitsLines(automation), id: \.self) { Text($0) }
        }
    }

    @ViewBuilder private var reports: some View {
        if let reports = vm.reports[automation.id], !reports.isEmpty {
            sectionBox("Latest reports") {
                ForEach(reports) { report in
                    DisclosureGroup {
                        MarkdownView(text: report.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        HStack {
                            Text(report.title)
                            Spacer()
                            if let created = report.createdAt {
                                Text("\(AutomationCardPresentation.relative(now.timeIntervalSince(created))) ago")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionBox(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
    }
}
