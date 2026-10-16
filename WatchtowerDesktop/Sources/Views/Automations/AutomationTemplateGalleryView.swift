import SwiftUI
import WatchtowerCore

/// "Start from a template" (spec §12.2, approved mockup 5): a card per
/// template and a last card that hands over to "Describe in words". **Use
/// template** installs through the `AppState`-owned `AutomationsViewModel`
/// (so the install survives closing the sheet); once it lands the tab opens
/// the new copy's edit form. Workbench templates wait for workbench
/// automations (P5), so their button is off.
struct AutomationTemplateGalleryView: View {
    @Bindable var vm: AutomationsViewModel
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
            ForEach(AutomationTemplateGallery.paramLines(template) + template.notes, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if isWorkbench {
                Button("Coming with workbench automations") {}
                    .disabled(true)
            } else {
                Button(vm.installingTemplate == template.name ? "Installing…" : "Use template") {
                    Task {
                        if await vm.installTemplate(template) { onClose() }
                    }
                }
                .disabled(vm.installingTemplate != nil)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
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
