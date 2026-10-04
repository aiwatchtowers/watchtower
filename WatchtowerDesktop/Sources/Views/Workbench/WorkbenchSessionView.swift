import AppKit
import SwiftUI
import WatchtowerCore

/// A session pane of a project page (spec §3): one `terminal_sessions` row
/// from `AppState.terminalCenter`, which owns the process — this view never
/// does. Not running (an app restart) → a button that resumes it.
/// The project's session errors show once, on the page (`WorkbenchPageView`).
struct WorkbenchSessionView: View {
    let projectID: Int64
    let sessionID: Int64
    @Environment(AppState.self) private var appState

    var body: some View {
        if let vm = appState.workbenchesViewModel {
            // The drawer opens beside the terminal of the session that filed
            // the ask (spec 2026-10-03 Part 8); the banner points at it.
            let drawerAsk = vm.asks.drawerAsk(projectID: projectID).flatMap { $0.sessionID == sessionID ? $0 : nil }
            let waiting = vm.asks.stack(projectID: projectID).asks.filter { $0.sessionID == sessionID }
            OwnerAskDrawerHost(vm: vm, ask: drawerAsk) {
                VStack(spacing: 0) {
                    if drawerAsk == nil, !waiting.isEmpty {
                        OwnerAskBanner(asks: waiting) { ask in vm.asks.openDrawer(ask) }
                        Divider()
                    }
                    pane
                }
            }
            .onGeometryChange(for: Bool.self, of: { OwnerAskDrawerLayout.fitsBeside(total: $0.size.width) }, action: { fits in
                vm.asks.setRoomBeside(fits, sessionID: sessionID)
                if fits { vm.openNewAsk(projectID: projectID) }
            })
        } else {
            pane
        }
    }

    private var pane: some View {
        let vm = appState.workbenchesViewModel
        let session = vm?.session(sessionID, projectID: projectID)
        let obscured = vm?.isObscured(sessionID: sessionID, projectID: projectID) ?? false
        return TerminalSessionPane(session: session, error: nil, obscured: obscured) {
            VStack(spacing: 8) {
                if let session {
                    Text("\(session.title) is not running.")
                        .foregroundStyle(.secondary)
                    Button(session.kind == .claude ? "Resume" : "Start") {
                        Task { await vm?.open(session, placement: .inPlace) }
                    }
                } else if vm?.sessionErrors[projectID] == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Try Again") { Task { await vm?.loadSessions(projectID: projectID) } }
                }
            }
        }
        // A layout restored before any list load names a row not read yet.
        .task(id: sessionID) {
            if vm?.session(sessionID, projectID: projectID) == nil { await vm?.loadSessions(projectID: projectID) }
        }
    }
}

/// A standalone terminal (no project, spec §3): always the whole page,
/// single pane, under a slim header — its folder, Rename and Delete
/// (the title is in the Workbench tab's title row). No install badge or board: nothing of a project.
struct StandaloneTerminalView: View {
    let session: TerminalSession
    /// The panel's row actions: Rename and Delete open the page's own sheet
    /// and confirmation (`sessionActionDialogs`).
    let actions: SessionRowActions
    @Environment(AppState.self) private var appState

    var body: some View {
        let vm = appState.workbenchesViewModel
        VStack(spacing: 0) {
            header
            Divider()
            TerminalSessionPane(session: session, error: vm?.standaloneSessionError) {
                VStack(spacing: 8) {
                    Text("\(session.title) is not running.")
                        .foregroundStyle(.secondary)
                    Button("Start") {
                        Task { await vm?.open(session) }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.folderPath)])
            } label: {
                Text(session.folderPath).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.link)
            .help("Reveal in Finder")
            Spacer()
            Button("Rename…") { actions.rename(session) }
            Button(role: .destructive) {
                actions.delete(session)
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
        .padding(10)
    }
}

/// One session's terminal with its state around it: the error line, the
/// clipboard hint, the exit bar (Restart / Start fresh), or `notStarted`
/// when the center runs nothing for it.
private struct TerminalSessionPane<NotStarted: View>: View {
    let session: TerminalSession?
    let error: String?
    /// Covered by an expanded ask drawer: the terminal never takes focus.
    var obscured = false
    @Environment(\.askDrawerCovers) private var drawerCovers
    @ViewBuilder let notStarted: () -> NotStarted
    @Environment(AppState.self) private var appState

    var body: some View {
        let center = appState.terminalCenter
        let state = session.flatMap { center.states[$0.id] }
        let vm = appState.workbenchesViewModel
        VStack(spacing: 0) {
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Divider()
            }
            switch state {
            case .running?:
                if let session, let delivery = center.answerHints[session.id] {
                    AnswerReturnHint(delivery: delivery) { center.dismissClipboardHint(sessionID: session.id) }
                    Divider()
                } else if let session, center.clipboardHints.contains(session.id) || center.pasteHints.contains(session.id) {
                    let copied = center.clipboardHints.contains(session.id)
                    HStack {
                        Label(copied ? OwnerAsksViewModel.copiedNote : OwnerAsksViewModel.sentNote,
                              systemImage: copied ? "doc.on.clipboard" : "checkmark")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") { center.dismissClipboardHint(sessionID: session.id) }
                            .controlSize(.small)
                    }
                    .padding(8)
                    Divider()
                }
                host(center)
            case let .exited(code)?:
                host(center)
                Divider()
                HStack {
                    Text(TerminalLaunch.exitMessage(code: code))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // A failed resume fails again on Restart: only a new id gets out.
                    if let session, vm?.resumeFailed.contains(session.id) == true {
                        Button("Start fresh") { Task { await vm?.startFresh(session, placement: .inPlace) } }
                    }
                    Button("Restart") {
                        if let session { Task { await vm?.open(session, placement: .inPlace) } }
                    }
                }
                .padding(8)
            case let .unavailable(message)?:
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                notStarted().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func host(_ center: TerminalCenter) -> some View {
        if let session, let process = center.process(for: session.id) {
            TerminalHost(session: process, focusSerial: center.keyboardFocusSerial(for: session.id),
                         obscured: obscured || drawerCovers)
        }
    }
}

/// Over a terminal holding an ask's answer not sent yet (board #364): typed
/// (press Return) or copied (paste, then Return). Prominent on purpose —
/// Watchtower never presses Return itself (PROJ-12). Goes with the owner's
/// next input in the session (`TerminalCenter.answerHints`) or Dismiss.
private struct AnswerReturnHint: View {
    let delivery: TerminalCenter.PromptDelivery
    let dismiss: () -> Void

    var body: some View {
        let copied = delivery == .copied
        HStack(spacing: 8) {
            Image(systemName: copied ? "doc.on.clipboard" : "return")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(copied ? OwnerAsksViewModel.answerCopiedNote : OwnerAsksViewModel.answerTypedNote)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss", action: dismiss)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.15))
    }
}

/// Hosts a session's NSView. Dismantling the host only removes the view from
/// the hierarchy — the center keeps it (and the process) alive.
private struct TerminalHost: NSViewRepresentable {
    let session: any TerminalSessionProcess
    /// `TerminalCenter.keyboardFocusSerial(for:)` of this session.
    let focusSerial: Int?
    /// Under an expanded ask drawer: no attach or request moves focus here.
    let obscured: Bool

    /// The focus request serial already honoured.
    final class Coordinator {
        var honouredSerial: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        attach(to: container, context.coordinator)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        attach(to: container, context.coordinator)
    }

    static func dismantleNSView(_ container: TerminalContainerView, coordinator: Coordinator) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: TerminalContainerView, _ coordinator: Coordinator) {
        let terminal = session.view
        let attached = TerminalHostAttachment.attach(terminal, to: container)
        let focus = TerminalHostAttachment.needsFocus(
            attached: attached, requested: focusSerial, honoured: coordinator.honouredSerial, obscured: obscured
        )
        coordinator.honouredSerial = focusSerial
        guard focus else { return }
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }
}

/// How a host shows one session's view. SwiftUI reuses the same host when the
/// page switches to another project, so the container can still hold the
/// previous project's terminal: it must be the only subview afterwards, or
/// switching back leaves the other project's terminal on top — on screen and
/// taking the keystrokes.
enum TerminalHostAttachment {
    /// Terminal.app-like inner margin on every side. The terminal's own frame
    /// is inset (not padded inside it), so SwiftTerm computes cols/rows from
    /// the space it really has and the last column is never clipped. What is
    /// left over past the last whole cell (right, bottom) SwiftTerm paints in
    /// the same background, so those edges read up to one cell wider.
    static let margin: CGFloat = 10

    /// `insetBy` would turn a container smaller than two margins into a null
    /// rect; this clamps to an empty frame instead.
    static func contentFrame(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX + margin, y: bounds.minY + margin,
               width: max(0, bounds.width - 2 * margin), height: max(0, bounds.height - 2 * margin))
    }

    /// Makes `terminal` the container's only subview. Returns whether
    /// anything changed (the caller then moves keyboard focus to it).
    @MainActor
    @discardableResult
    static func attach(_ terminal: NSView, to container: NSView) -> Bool {
        let others = container.subviews.filter { $0 !== terminal }
        if terminal.superview === container, others.isEmpty { return false }
        others.forEach { $0.removeFromSuperview() }
        if terminal.superview !== container {
            terminal.removeFromSuperview()
            terminal.frame = contentFrame(in: container.bounds)
            container.addSubview(terminal)
        }
        return true
    }

    /// Whether the host moves the keyboard into its terminal: after an
    /// attach that changed something, or for a focus request
    /// (`TerminalCenter.requestKeyboardFocus`) it has not honoured yet —
    /// never while an expanded ask drawer covers it (`obscured`; such a
    /// request is dropped, not kept for later).
    static func needsFocus(attached: Bool, requested: Int?, honoured: Int?, obscured: Bool = false) -> Bool {
        !obscured && (attached || (requested != nil && requested != honoured))
    }

    /// Whether the keyboard is in a session's terminal (a view inside a
    /// `TerminalContainerView`) of `window`.
    @MainActor
    static func terminalHasFocus(in window: NSWindow?) -> Bool {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if current is TerminalContainerView { return true }
            view = current.superview
        }
        return false
    }
}

/// The host's container: keeps its terminal inset by `TerminalHostAttachment.margin`
/// on every resize, and fills the margin with the terminal layer's own
/// background — observed, so an OSC 11 colour change or reverse video
/// (both repaint SwiftTerm's layer) recolours the margin with it, and the
/// padding never reads as a differently coloured frame. (That is SwiftTerm's
/// default CPU renderer; its opt-in Metal renderer clears the layer instead.)
final class TerminalContainerView: NSView {
    private weak var observedTerminal: NSView?
    private var backgroundObservation: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        subviews.forEach { $0.frame = TerminalHostAttachment.contentFrame(in: bounds) }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        observedTerminal = subview
        backgroundObservation = subview.layer?.observe(\.backgroundColor, options: [.initial, .new]) { [weak self] terminalLayer, _ in
            let color = terminalLayer.backgroundColor
            MainActor.assumeIsolated { self?.layer?.backgroundColor = color }
        }
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        guard subview === observedTerminal else { return }
        backgroundObservation = nil
        observedTerminal = nil
        layer?.backgroundColor = nil
    }
}
