import DesignKit
import SwiftUI
import WatchtowerCore

/// The company connect sheet (screens spec §3.1–§3.3): the confirm with one
/// checkbox per vendor, the chain's progress, the done summary and the
/// replace warning. Every string comes from `CompanyConnectFlowModel`; this
/// view lays it out and hands each button back to the model.
struct CompanyConnectSheet: View {
    @Bindable var flow: CompanyConnectFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            switch flow.phase {
            case .idle:
                EmptyView()
            case .confirm:
                header
                checks
                caption
                buttons
            case let .replace(changes):
                notice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, title: flow.title, body: flow.body ?? "")
                changeList(changes)
                buttons
            case .chain, .done:
                header
                progress
                // The done summary's line sits under the list.
                if flow.phase == .done, let body = flow.body {
                    Text(body).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                buttons
            case let .problem(message):
                notice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, title: nil, body: message)
                buttons
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    @ViewBuilder private var header: some View {
        if let title = flow.title { Text(title).font(.title3.weight(.semibold)) }
        if flow.managed { ManagedByOrganizationBadge() }
        if let body = flow.body, flow.phase != .done {
            Text(body).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var caption: some View {
        if let caption = flow.caption {
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            ForEach(flow.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Toggle(isOn: Binding(get: { row.ticked || row.connected }, set: { _ in flow.toggle(row.vendor) })) {
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(row.title).font(.callout).foregroundStyle(row.enabled ? .primary : .secondary)
                            Text(flow.confirmDetail(row)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!row.enabled || flow.working)
                    Spacer(minLength: Spacing.regular)
                    if row.connected {
                        Chip(text: CompanyConnectFlowModel.alreadyConnected, color: Tone.success, dot: true)
                    } else if row.forbidden {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(flow.rows) { row in
                let line = flow.progress(row)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    mark(line.mark)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(row.title).font(.callout).foregroundStyle(line.mark == .pending ? .secondary : .primary)
                        if let detail = line.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            caption
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func changeList(_ changes: [CompanyConnectFlowModel.Change]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(changes, id: \.line) { change in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    mark(.pending)
                    Text(change.line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            caption
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func mark(_ mark: CompanyConnectFlowModel.RowMark) -> some View {
        Group {
            switch mark {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success)
            case .running: ProgressView().controlSize(.small)
            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Tone.status("gray"))
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            }
        }
        .frame(width: ListLayout.markColumn)
    }

    private func notice(icon: String, tone: Color, title: String?, body: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(tone)
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let title { Text(title).font(.headline).fixedSize(horizontal: false, vertical: true) }
                Text(body).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: Spacing.regular) {
            if let error = flow.connectError {
                Text(error).font(.caption).foregroundStyle(Tone.error).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.regular)
            switch flow.phase {
            case .confirm:
                Button(CompanyConnectFlowModel.cancelTitle) { flow.cancel() }
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(CompanyConnectFlowModel.connectTitle) { Task { await flow.connect() } }
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canConnect)
            case .replace:
                Button(CompanyConnectFlowModel.replaceTitle) { Task { await flow.replace() } }
                    .buttonStyle(.kitSecondary)
                    .disabled(flow.working)
                Button(CompanyConnectFlowModel.keepCurrentTitle) { flow.keepCurrent() }
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.working)
            case .chain:
                Button(CompanyConnectFlowModel.stopTitle) { flow.stop() }
                    .buttonStyle(.kitSecondary)
                Button(CompanyConnectFlowModel.skipTitle) { flow.skipCurrent() }
                    .buttonStyle(.kitSecondary)
                    .disabled(flow.currentVendor == nil)
            case .done:
                Button(CompanyConnectFlowModel.doneTitle) { flow.finish() }
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut(.defaultAction)
            case .problem:
                Button(CompanyConnectFlowModel.closeTitle) { flow.finish() }
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut(.defaultAction)
            case .idle:
                EmptyView()
            }
        }
    }
}
