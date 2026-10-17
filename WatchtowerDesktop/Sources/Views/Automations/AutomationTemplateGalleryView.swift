import SwiftUI
import WatchtowerCore

/// "Start from a template" (spec §12.2, approved mockup 5): a card per
/// template and a last card that hands over to "Describe in words". **Use
/// template** installs through the `AppState`-owned `AutomationsViewModel`
/// (so the install survives closing the sheet); once it lands the tab opens
/// the new copy's edit form. A workbench template installs into the only
/// workbench, or into the one picked from the button's menu (#582).
struct AutomationTemplateGalleryView: View {
    @Bindable var vm: AutomationsViewModel
    var workbenches: [AutomationTemplateGallery.InstallTarget] = []
    let onDescribeInWords: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = vm.installError ?? vm.templatesError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(vm.templates) { template in
                        card(template)
                    }
                    describeCard
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                if vm.templates.isEmpty, !vm.templatesLoading, vm.templatesError == nil {
                    Text("No templates yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 20)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 480, idealHeight: 620)
        .task { await vm.loadTemplates() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start from a template").font(.title3.weight(.semibold))
                Text("Installs a copy you can change. It stays off until you confirm it.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func card(_ template: AutomationTemplate) -> some View {
        let isWorkbench = template.scope == "workbench"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(template.title).font(.headline)
                Spacer(minLength: 8)
                Text(isWorkbench ? "Workbench" : "Personal")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isWorkbench ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            Text(template.description)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(AutomationTemplateGallery.summaryLine(template))
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(template.notes, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            useButton(template)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
    }

    /// **Use template**: installs at once, or, for a workbench template with
    /// several workbenches, is a menu of them.
    @ViewBuilder private func useButton(_ template: AutomationTemplate) -> some View {
        let title = vm.installingTemplate == template.name ? "Installing…" : "Use template"
        switch AutomationTemplateGallery.installChoice(template, workbenches: workbenches) {
        case let .install(workbenchID):
            Button(title) { install(template, workbenchID: workbenchID) }
                .disabled(vm.installingTemplate != nil)
        case let .pickWorkbench(choices):
            Menu(title) {
                ForEach(choices) { workbench in
                    Button(workbench.name) { install(template, workbenchID: workbench.id) }
                }
            }
            .fixedSize()
            .disabled(vm.installingTemplate != nil)
        case .needsWorkbench:
            Button(title) {}
                .disabled(true)
                .help("Add a workbench first: this template goes into a workbench folder.")
        }
    }

    private func install(_ template: AutomationTemplate, workbenchID: Int64?) {
        Task {
            if await vm.installTemplate(template, workbenchID: workbenchID) { onClose() }
        }
    }

    private var describeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Something else?").font(.headline)
            Text("Describe it in words and the assistant drafts the recipe.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Describe in words", action: onDescribeInWords)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4])))
    }
}
