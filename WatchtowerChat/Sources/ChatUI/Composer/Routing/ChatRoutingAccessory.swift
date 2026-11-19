import ChatWire
import SwiftUI
import WatchtowerDesign

/// The routing accessory of the main chat's composer on the Mac and the phone (#1822 T17): the provider that answers,
/// what it lacks, the fallback card with **Use preferred**, the claude.ai-tools notice, the routing error, and the
/// pill (off while a turn runs). The phone also gets its project menu beside the pill (a new chat only; locked text
/// once saved). It refreshes the routing status on a chat change, at a turn's end and on app activation.
public struct ChatRoutingAccessory: View {
    let model: ChatRoutingModel
    let isBusy: Bool
    let reachable: Bool
    let projects: ChatNewChatChoices?
    let projectID: Binding<Int64?>?
    @Environment(\.chatUIStyle) private var style

    public init(
        model: ChatRoutingModel,
        isBusy: Bool,
        reachable: Bool,
        projects: ChatNewChatChoices? = nil,
        projectID: Binding<Int64?>? = nil
    ) {
        self.model = model
        self.isBusy = isBusy
        self.reachable = reachable
        self.projects = projects
        self.projectID = projectID
    }

    public var body: some View {
        if model.showsPill {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if let presentation = model.presentation {
                    lines(presentation).padding(.horizontal, ComposerMetrics.routingInset)
                }
                HStack(spacing: Spacing.compact) {
                    ChatRoutingPill(label: model.label, menu: model.menu, enabled: !isBusy) { model.pick($0) }
                    projectChip
                }
                .padding(.horizontal, ComposerMetrics.routingInset)
                .padding(.bottom, ComposerMetrics.routingBottom)
            }
            .task(id: model.composer.conversation.conversationID) { await model.conversationChanged() }
            .onChange(of: isBusy) { _, busy in
                if !busy { Task { await model.turnEnded() } }
            }
            .onAppActivation { Task { await model.activated() } }
        }
    }

    private func lines(_ presentation: ChatRoutingPresentation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let actual = presentation.actual { style.routingCaption(actual, warning: false) }
            // U3: what the provider lacks (images among them, U1).
            if let missing = presentation.missingCapabilities { style.routingCaption(missing, warning: false) }
            if let preview = presentation.preview {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    if let notice = presentation.nativeToolsNotice { style.routingCaption(notice, warning: true) }
                    style.routingStatusCard(preview.copy, actionEnabled: !isBusy && reachable,
                                            onAction: preview.state == .recovered ? { Task { await model.usePreferred() } } : nil)
                }
            }
            if let error = model.catalog?.statusError { style.routingCaption(error, warning: true) }
            if let notice = model.notice { style.routingCaption(notice, warning: true) }
        }
    }

    /// R12: the phone's project menu on a new chat, its project as locked text once saved; nothing on the Mac.
    @ViewBuilder private var projectChip: some View {
        if let projects, let chip = model.composer.projectChip {
            if chip.editable, let projectID {
                Menu {
                    Button(ChatComposerModel.noProject) { projectID.wrappedValue = nil }
                    ForEach(projects.projects) { project in Button(project.name) { projectID.wrappedValue = project.id } }
                } label: { style.chip(chip.label + " ⌄") }
                .accessibilityIdentifier("chat.composer.project")
            } else {
                style.chip(chip.label)
            }
        }
    }
}
