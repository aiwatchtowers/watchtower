import SwiftUI
import WatchtowerCore

/// "Confirm “<name>”?" (spec §12.2, approved mockup 3; AUTO-06): what
/// changed since the last confirmation, who changed it, what it may do, the
/// script read-only, and **Dry run first** / **Not now** / **Confirm**. The
/// confirm passes exactly the approval hash shown here; a stale one reloads
/// the sheet. The detail is the card's `show --json` in `AutomationsViewModel`.
struct AutomationConfirmSheet: View {
    @Bindable var vm: AutomationsViewModel
    @Bindable var editor: AutomationEditorCenter
    let automationID: Int64
    let onClose: () -> Void

    @State private var scriptBuffer: RecipeBufferModel?
    @State private var scriptShown = false

    private var detail: AutomationDetail? { vm.details[automationID] }
    private var state: AutomationEditorCenter.ConfirmState? { editor.confirmations[automationID] }
    private var isConfirming: Bool { state == .confirming }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail {
                ScrollView {
                    content(detail)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                buttons(detail)
                    .padding(16)
            } else if let error = vm.detailErrors[automationID] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(24)
                closeOnly
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .frame(width: 600)
        .frame(minHeight: 360, idealHeight: 560)
        .task { await vm.loadDetail(automationID) }
        .task(id: detail?.contentHash) { syncScriptBuffer() }
        .onChange(of: state) { _, new in
            if new == .done { close() }
        }
    }

    private func syncScriptBuffer() {
        guard let detail else { return }
        if let scriptBuffer {
            if scriptBuffer.baseContentHash != detail.contentHash {
                scriptBuffer.reset(text: detail.recipeText, contentHash: detail.contentHash)
            }
        } else {
            scriptBuffer = RecipeBufferModel(automationID: detail.id, text: detail.recipeText,
                                             contentHash: detail.contentHash)
        }
    }

    private func close() {
        editor.closeConfirmation(automationID)
        onClose()
    }

    // MARK: - Content

    @ViewBuilder private func content(_ detail: AutomationDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Confirm “\(detail.name)”?")
                    .font(.title2.weight(.semibold))
                Text("The recipe changed since you last confirmed it. It won't run again until you confirm. "
                    + "Changes are marked.")
                    .foregroundStyle(.secondary)
            }
            if case let .stale(message) = state {
                Label(message, systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
            if case let .failed(message) = state {
                Label(message, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            changed(detail)
            mayDo(detail)
            script(detail)
            Text("Approval hash \(String(detail.approvalHash.prefix(12)))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private func changed(_ detail: AutomationDetail) -> some View {
        let lines = AutomationChangePresentation.lines(
            detail.changes, known: detail.changesKnown, confirmedBefore: !detail.confirmedHash.isEmpty
        )
        if !lines.isEmpty {
            section("Changed") {
                ForEach(lines, id: \.self) { Text($0) }
                Text(AutomationChangePresentation.authorLine(changedBy: detail.changedBy, changedAt: detail.changedAt,
                                                             now: Date()))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func mayDo(_ detail: AutomationDetail) -> some View {
        let widening = Set(detail.widening)
        return section("It may") {
            ForEach(detail.permissions, id: \.self) { permission in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(permission)
                        .font(.callout.monospaced())
                        .foregroundStyle(widening.contains(permission) ? .orange : .secondary)
                    Text(AutomationCardPresentation.permissionLine(permission))
                    if widening.contains(permission) {
                        Text("new")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            ForEach(detail.outputs, id: \.self) { output in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("output: \(output)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                    Text(AutomationCardPresentation.outputLine(output))
                }
            }
            if widening.isEmpty {
                Text("No change to what it can access.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func script(_ detail: AutomationDetail) -> some View {
        let count = detail.script.split(separator: "\n", omittingEmptySubsequences: false).count
            - (detail.script.hasSuffix("\n") ? 1 : 0)
        DisclosureGroup("Show the script (\(count) \(count == 1 ? "line" : "lines"))", isExpanded: $scriptShown) {
            if let scriptBuffer {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = scriptBuffer.pageError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    RecipeEditorView(buffer: scriptBuffer, readOnly: true, slug: detail.slug)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Buttons

    private func buttons(_ detail: AutomationDetail) -> some View {
        HStack(spacing: 8) {
            if isConfirming {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Dry run first") {
                let id = automationID
                Task { await vm.dryRun(id) }
                close()
            }
            .disabled(isConfirming)
            Button("Not now", action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(isConfirming)
            if detail.enabled {
                confirmButton("Confirm", hash: detail.approvalHash, enable: false)
            } else {
                Button("Confirm") { confirm(hash: detail.approvalHash, enable: false) }
                    .disabled(isConfirming)
                confirmButton("Confirm and enable", hash: detail.approvalHash, enable: true)
            }
        }
    }

    private func confirmButton(_ title: String, hash: String, enable: Bool) -> some View {
        Button(title) { confirm(hash: hash, enable: enable) }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isConfirming || hash.isEmpty)
    }

    private func confirm(hash: String, enable: Bool) {
        let id = automationID
        Task { await editor.confirmForeign(id, shownHash: hash, enable: enable) }
    }

    private var closeOnly: some View {
        HStack {
            Spacer()
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }
}
