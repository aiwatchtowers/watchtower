import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerCore

private typealias Model = CompanySetupWizardModel

/// **What does your company use?** (company screens spec §2.3): one checkbox
/// per supported service, the unreadable-draft warning, the in-place warning
/// before a filled step is dropped, and the Quick Connections note.
struct CompanySetupServicesStep: View {
    let model: CompanySetupWizardModel
    let actions: CompanySetupActions
    /// Opens the page's Discard confirmation.
    let askDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            if let unreadable = model.draftUnreadable {
                WizardNotice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, title: unreadable.title,
                             text: unreadable.body)
                HStack(spacing: Spacing.regular) {
                    Button(Model.showInFinder) { actions.showFile(unreadable.file) }.buttonStyle(.kitQuiet)
                    // Discard deletes the set-aside file and the secrets in it (§2.2).
                    Button(Model.discardSetup) { askDiscard() }.buttonStyle(.kitQuiet)
                }
            }
            WizardCaption(CompanyVendorGuide.servicesBody)
            VStack(alignment: .leading, spacing: Spacing.compact) {
                ForEach(model.servicesRows, id: \.vendor) { row in
                    WizardCheckRow(title: row.title, detail: row.detail, checked: row.ticked) { model.toggle(row.vendor) }
                }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            if let warning = model.dropWarning {
                WizardNotice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, title: warning.title, text: warning.body)
                HStack(spacing: Spacing.regular) {
                    Spacer(minLength: Spacing.regular)
                    Button(warning.keep) { model.keepService() }.buttonStyle(.kitPrimary)
                    Button(warning.drop) { model.confirmDrop(warning.vendor) }.buttonStyle(.kitDestructive)
                }
            } else {
                WizardCaption(CompanyVendorGuide.mcpNote)
                Button(CompanyVendorGuide.openQuickConnections) { actions.openQuickConnections() }.buttonStyle(.kitQuiet)
            }
        }
    }
}

/// **Link deny list** (§2.9): the field, its error, and the hosts with Remove.
struct CompanySetupDenyListStep: View {
    @Bindable var model: CompanySetupWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            WizardCaption(Model.denyBody)
            HStack(alignment: .bottom, spacing: Spacing.regular) {
                WizardField(label: Model.addHostLabel, text: $model.hostField)
                    .onSubmit { model.addHost() }
                Button(Model.addTitle) { model.addHost() }
                    .buttonStyle(.kitSecondary)
                    .disabled(model.hostField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if model.hostInvalid {
                Text(Model.denyInvalid).font(.caption).foregroundStyle(Tone.error).fixedSize(horizontal: false, vertical: true)
            }
            if !model.draft.denyHosts.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    ForEach(model.draft.denyHosts, id: \.self) { host in
                        WizardValueRow(label: "", value: host, button: Model.removeTitle) { model.removeHost(host) }
                    }
                }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
        }
    }
}

/// The client JSON's drop zone (Google): drop a file, paste the JSON, or
/// click to choose the file.
struct WizardDropZone: View {
    let model: CompanySetupWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            let line = model.droppedGoogleLine
            Button(action: choose) {
                HStack(spacing: Spacing.regular) {
                    Image(systemName: line == nil ? "square.and.arrow.down" : "doc.text")
                        .foregroundStyle(line == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.success))
                    Text(line ?? Model.dropJSON).font(.callout).foregroundStyle(line == nil ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
                .padding(Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .card()
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: nil, perform: drop)
            .onPasteCommand(of: [.json, .plainText, .utf8PlainText]) { _ in paste() }
            if model.googleFileProblem { WizardProblem(text: Model.googleFileInvalid) }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        read(url)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in read(url) }
        }
        return true
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        model.dropGoogleClient(Data(text.utf8), fileName: Model.pastedJSON)
    }

    private func read(_ url: URL) {
        // An unreadable file is the same refusal as a wrong one.
        let data = (try? Data(contentsOf: url)) ?? Data()
        model.dropGoogleClient(data, fileName: url.lastPathComponent)
    }
}
