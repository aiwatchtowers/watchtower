import SwiftUI
import WatchtowerCore

/// `● <session> ▾` (board #251, variant H): the collapsed title row's
/// session switcher — the session in focus, and a popover of the
/// workbench's sessions in the panel's order.
struct SessionSwitcher: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    @State private var showsPopover = false

    var body: some View {
        let session = vm.headerSession
        SessionSwitcherButton(title: session?.title, isLive: session.map(vm.isLive) ?? false) {
            showsPopover.toggle()
        }
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            SessionSwitcherPopover(
                vm: vm,
                project: project,
                currentID: session?.id,
                onSelect: { id in
                    showsPopover = false
                    Task { await vm.showFromPanel(sessionID: id) }
                },
                onNewSession: {
                    showsPopover = false
                    Task { await vm.newPanelSession() }
                },
                onShowPanel: {
                    showsPopover = false
                    vm.panelVisible = true
                }
            )
        }
    }
}

/// The session switcher's button: a green dot while the session runs (a
/// hollow one otherwise), its title — "No session" when none is in focus —
/// and a chevron.
struct SessionSwitcherButton: View {
    let title: String?
    let isLive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if title != nil { SessionLiveDot(isLive: isLive) }
                Text(title ?? "No session")
                    .font(.headline)
                    .foregroundStyle(title == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("\(title ?? "No session") — Switch Session")
        .accessibilityLabel(title.map { "Session \($0), \(isLive ? "running" : "not running")" } ?? "No session")
        .accessibilityHint("Switch session")
    }
}
