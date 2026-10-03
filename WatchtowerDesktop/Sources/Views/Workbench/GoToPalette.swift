import AppKit
import SwiftUI
import WatchtowerCore

/// ⌘K on the Workbench tab (board #252, variant I): find a session or a
/// workbench by name — or a session by `#id` — and go there. A centered
/// card over a dimmed backdrop inside `WorkbenchesView`, not a window; a
/// click on the backdrop closes it. Session and workbench names only, never
/// documents (PROJ-08). Closing hands the keyboard back to whatever had it
/// before; an open then moves it into the terminal opened
/// (`TerminalCenter.requestKeyboardFocus`).
struct GoToPaletteOverlay: View {
    @Bindable var vm: WorkbenchesViewModel
    let onClose: () -> Void
    @State private var previousResponder = PreviousFirstResponder()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            GoToPalette(vm: vm, onClose: close)
                .padding(.top, 90)
                .padding(.horizontal, 16)
        }
        .onAppear { previousResponder.capture() }
    }

    private func close() {
        onClose()
        previousResponder.restore()
    }
}

/// The key window's first responder when the palette opened — a terminal,
/// the Files editor, a text field — held weakly.
@MainActor
final class PreviousFirstResponder {
    private weak var window: NSWindow?
    private weak var responder: NSResponder?

    func capture() {
        window = NSApp.keyWindow
        var current = window?.firstResponder
        // A text field's editor stands in for the field, which is what comes back.
        if let editor = current as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
            current = field
        }
        responder = current
    }

    /// After the palette's field leaves the window; a responder no longer
    /// in it is left alone.
    func restore() {
        guard let window, let responder else { return }
        if let view = responder as? NSView, view.window !== window { return }
        DispatchQueue.main.async { window.makeFirstResponder(responder) }
    }
}

/// The palette's card: the search field, the two sections, the key hints.
/// ↑↓ ↵ ⌘↵ esc go through `GoToPaletteSelection`.
struct GoToPalette: View {
    @Bindable var vm: WorkbenchesViewModel
    let onClose: () -> Void
    @State private var query = ""
    @State private var selection = GoToPaletteSelection()
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sections = vm.goToSections(query: query)
        let items = sections.flatMap(\.items)
        let selectedID = selection.selected(in: items)?.id
        VStack(alignment: .leading, spacing: 0) {
            TextField("Go to session or workbench…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .padding(12)
            Divider()
            results(sections, selectedID: selectedID)
            Divider()
            Text("↑↓ select   ↵ open   ⌘↵ open in split   esc close")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: 600)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .background { keys(items) }
        .onChange(of: query) { _, _ in selection.reset() }
        .task {
            searchFocused = true
            await vm.loadGoToPalette()
        }
    }

    @ViewBuilder
    private func results(_ sections: [GoToSection], selectedID: String?) -> some View {
        let errors = vm.goToErrors
        if !errors.isEmpty {
            Text(errors.joined(separator: "\n"))
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
        if sections.isEmpty {
            // A failed read is no proof that nothing matches.
            if errors.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No session or workbench matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        } else {
            let now = vm.now()
            let currentRows = currentSessionRows(now: now)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(sections) { section in
                            header(section)
                            ForEach(section.items) { item in
                                row(item, isSelected: item.id == selectedID, currentRows: currentRows, now: now)
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    /// The page's sessions as the session switcher shows them (state
    /// caption, `#id` badge), by id.
    private func currentSessionRows(now: Date) -> [Int64: SessionSwitcherPresentation.Row] {
        guard let projectID = vm.selectedWorkbenchID else { return [:] }
        let rows = SessionSwitcherPresentation.rows(
            vm.orderedSessions(projectID: projectID), liveIDs: vm.terminalCenter?.liveIDs ?? [], statuses: vm.sessionStatuses, now: now
        )
        return Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
    }

    private func header(_ section: GoToSection) -> some View {
        Text(GoToPresentation.sectionTitle(section.kind, currentWorkbench: vm.selectedWorkbench?.name ?? ""))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(
        _ item: GoToItem, isSelected: Bool, currentRows: [Int64: SessionSwitcherPresentation.Row], now: Date
    ) -> some View {
        Button { perform(.open(item)) } label: {
            HStack(spacing: 6) {
                rowContent(item, currentRows: currentRows, now: now)
                if isSelected {
                    Text("↵").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selection.select(item.id) } }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func rowContent(
        _ item: GoToItem, currentRows: [Int64: SessionSwitcherPresentation.Row], now: Date
    ) -> some View {
        switch item {
        case let .session(session, workbench):
            if let row = currentRows[session.id] {
                SessionLiveDot(state: row.state).frame(width: 12)
                Text(row.session.title).font(.callout).lineLimit(1).truncationMode(.tail)
                if let badge = row.badge { WorkbenchCapsuleBadge(text: badge) }
                Spacer(minLength: 4)
                if let caption = row.caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            } else {
                SessionLiveDot(state: vm.sessionState(session)).frame(width: 12)
                Text(GoToPresentation.sessionTitle(session, workbench: workbench, currentWorkbenchID: vm.selectedWorkbenchID))
                    .font(.callout).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text("session").font(.caption2).foregroundStyle(.secondary).fixedSize()
            }
        case let .workbench(row):
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary).frame(width: 12)
            Text(row.project.name).font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            WorkbenchStateSegments(segments: WorkbenchSwitcherPresentation.stateSegments(
                summary: row, newComments: vm.badgeCount(for: row.summary),
                liveCount: vm.liveSessionCount(workbenchID: row.id), now: now
            ))
        }
    }

    /// Hidden buttons: the field keeps the focus while the keys reach these
    /// (key equivalents run before the field editor sees the key). Should
    /// one not fire with the field focused, the fallback on the TextField is
    /// `.onKeyPress(.upArrow)` / `.onKeyPress(.downArrow)` returning
    /// `.handled`, `.onKeyPress(.return) { press in … press.modifiers.contains(.command)
    /// ? .openInSplit : .open … }` and `.onExitCommand` for esc.
    private func keys(_ items: [GoToItem]) -> some View {
        Group {
            Button("") { handle(.up, items) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { handle(.down, items) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { handle(.open, items) }.keyboardShortcut(.return, modifiers: [])
            Button("") { handle(.openInSplit, items) }.keyboardShortcut(.return, modifiers: .command)
            Button("") { handle(.close, items) }.keyboardShortcut(.escape, modifiers: [])
        }
        .hidden()
    }

    private func handle(_ key: GoToPaletteSelection.Key, _ items: [GoToItem]) {
        perform(selection.handle(key, items: items, currentWorkbenchID: vm.selectedWorkbenchID))
    }

    private func perform(_ outcome: GoToPaletteSelection.Outcome) {
        switch outcome {
        case .ignored:
            break
        case .close:
            onClose()
        case let .open(item):
            onClose()
            Task { await vm.goTo(item) }
        case let .openInSplit(session):
            onClose()
            Task { await vm.openInSplit(session: session) }
        }
    }
}
