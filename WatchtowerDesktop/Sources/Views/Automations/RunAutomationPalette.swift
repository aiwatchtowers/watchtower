import AppKit
import SwiftUI
import WatchtowerCore

/// Puts the "Run Automation…" palette and its "Run “<name>”?" sheet over
/// the main window's root content — above every destination, so ⌃⌘R opens
/// the same palette on every tab (owner ruling 2026-10-15, spec §12.7).
struct RunAutomationPaletteHost: ViewModifier {
    @Bindable var appState: AppState

    func body(content: Content) -> some View {
        content
            .overlay {
                if appState.isRunAutomationPaletteShown, let center = appState.quickRunCenter {
                    RunAutomationPalette(center: center) { appState.isRunAutomationPaletteShown = false }
                }
            }
            .sheet(item: confirming) { row in
                if let center = appState.quickRunCenter {
                    QuickRunConfirmSheet(row: row, center: center)
                }
            }
    }

    /// The center's pending `confirm: true` recipe; dismissing the sheet cancels it.
    private var confirming: Binding<QuickRunRow?> {
        Binding(
            get: { appState.quickRunCenter?.pendingConfirm },
            set: { if $0 == nil, appState.quickRunCenter?.pendingConfirm != nil { appState.quickRunCenter?.cancelConfirm() } }
        )
    }
}

/// "Run Automation…" (⌃⌘R, approved mockup 6): a centered card over a
/// dimmed backdrop with a "Search commands" field, the **Run automation**
/// rows ranked by `QuickRunCatalog.ranked` and an **Other** section. ↩ on a
/// runnable row runs it (a `confirm: true` one asks first); on a dimmed row
/// it opens the confirmation sheet or the card, never a run. Closing hands
/// the keyboard back to whatever had it (a terminal, the Files editor).
struct RunAutomationPalette: View {
    @Bindable var center: QuickRunCenter
    let onClose: () -> Void

    private enum Entry: Identifiable, Equatable {
        case row(QuickRunRow)
        case openAutomations

        var id: String {
            switch self {
            case let .row(row): "automation-\(row.id)"
            case .openAutomations: "open-automations"
            }
        }
    }

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var activating = false
    @State private var previousResponder = PreviousFirstResponder()
    @FocusState private var searchFocused: Bool

    var body: some View {
        let rows = QuickRunCatalog.ranked(center.rows, query: query)
        let entries = rows.map(Entry.row) + [.openAutomations]
        let selected = entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            card(rows: rows, entries: entries, selected: selected)
                .padding(.top, 90)
                .padding(.horizontal, 16)
        }
        .onAppear { previousResponder.capture() }
    }

    private func card(rows: [QuickRunRow], entries: [Entry], selected: Entry?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .accessibilityLabel("Search commands")
                Text("esc").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(12)
            Divider()
            if let error = center.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        header("Run automation")
                        if rows.isEmpty {
                            Text(center.rows.isEmpty ? "No automations yet." : "No automation matches.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if entry == .openAutomations { header("Other") }
                            entryRow(entry, index: index, isSelected: entry == selected).id(entry.id)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selected?.id) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Divider()
            Text("↑↓ select   ↵ run or open   esc close")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: 640)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .background { keys(entries) }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .task { searchFocused = true }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func entryRow(_ entry: Entry, index: Int, isSelected: Bool) -> some View {
        Button { perform(entry) } label: {
            HStack(spacing: 10) {
                switch entry {
                case let .row(row):
                    rowLabel(row)
                    Spacer(minLength: 8)
                    if isSelected, row.state == .runnable {
                        Text("↩ run")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.5)))
                    }
                case .openAutomations:
                    Text("Open Automations").font(.callout)
                    Spacer(minLength: 8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(activating)
        .onHover { if $0 { selectedIndex = index } }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rowLabel(_ row: QuickRunRow) -> some View {
        let dimmed = row.reason != nil
        return VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(dimmed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail(row))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// "<workbench> workbench · <hint> · last run …", or for a dimmed row
    /// "<reason> — ↩ opens it".
    private func detail(_ row: QuickRunRow) -> String {
        if let reason = row.reason { return "\(reason) — ↩ opens it" }
        let scope = switch row.group {
        case let .workbench(_, name): "\(name) workbench"
        case .personal: "personal"
        }
        let running: String? = if case .running = row.state { "running — ↩ opens it" } else { nil }
        return ([scope, row.hint, running ?? row.lastRunText(now: Date())] as [String?])
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Hidden buttons: the field keeps the focus while ↑↓↩esc reach these
    /// (key equivalents run before the field editor sees the key), as in
    /// the Go to… palette.
    private func keys(_ entries: [Entry]) -> some View {
        Group {
            Button("") { move(-1, count: entries.count) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { move(1, count: entries.count) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") {
                if entries.indices.contains(selectedIndex) { perform(entries[selectedIndex]) }
            }
            .keyboardShortcut(.return, modifiers: [])
            Button("", action: close).keyboardShortcut(.escape, modifiers: [])
        }
        .hidden()
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    private func perform(_ entry: Entry) {
        guard !activating else { return }
        switch entry {
        case .openAutomations:
            center.openAutomations()
            close()
        case let .row(row):
            activating = true
            Task {
                let outcome = await center.activate(row, origin: .palette)
                activating = false
                if case .refused = outcome { return }
                close()
            }
        }
    }

    private func close() {
        onClose()
        previousResponder.restore()
    }
}
