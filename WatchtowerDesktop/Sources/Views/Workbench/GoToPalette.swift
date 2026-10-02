import SwiftUI
import WatchtowerCore

/// ⌘K on the Workbench tab (board #252, variant I): find a session or a
/// workbench by name — or a session by `#id` — and go there. A centered
/// card over a dimmed backdrop inside `WorkbenchesView`, not a window; a
/// click on the backdrop closes it. Session and workbench names only, never
/// documents (PROJ-08).
struct GoToPaletteOverlay: View {
    @Bindable var vm: WorkbenchesViewModel
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
            GoToPalette(vm: vm, onClose: onClose)
                .padding(.top, 90)
                .padding(.horizontal, 16)
        }
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
        .background { keys(items) }
        .onChange(of: query) { _, _ in selection.reset() }
        .task {
            searchFocused = true
            await vm.loadGoToPalette()
        }
    }

    @ViewBuilder
    private func results(_ sections: [GoToSection], selectedID: String?) -> some View {
        if let error = vm.goToError ?? vm.switcherError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
        if sections.isEmpty {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No session or workbench matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        } else {
            let now = vm.now()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(sections) { section in
                            header(section)
                            ForEach(section.items) { item in
                                row(item, isSelected: item.id == selectedID, now: now)
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

    private func header(_ section: GoToSection) -> some View {
        let title = switch section.kind {
        case .currentSessions: "SESSIONS · \((vm.selectedWorkbench?.name ?? "").uppercased())"
        case .otherWorkbenches: "OTHER WORKBENCHES"
        }
        return Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: GoToItem, isSelected: Bool, now: Date) -> some View {
        Button { perform(.open(item)) } label: {
            HStack(spacing: 6) {
                rowContent(item, now: now)
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
    private func rowContent(_ item: GoToItem, now: Date) -> some View {
        switch item {
        case let .session(session, workbench):
            let live = vm.isLive(session)
            SessionLiveDot(isLive: live).frame(width: 12)
            if workbench.id == vm.selectedWorkbenchID {
                Text(session.title).font(.callout).lineLimit(1).truncationMode(.tail)
                if let target = session.targetID {
                    Text("#\(target)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue, in: Capsule())
                }
                Spacer(minLength: 4)
                if let caption = SessionSwitcherPresentation.rows([session], liveIDs: live ? [session.id] : [], now: now)
                    .first?.caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            } else {
                Text("\(workbench.name) › \(session.title)").font(.callout).lineLimit(1).truncationMode(.tail)
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

    /// Hidden buttons: the field keeps the focus while the keys reach these.
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
        case .none:
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
