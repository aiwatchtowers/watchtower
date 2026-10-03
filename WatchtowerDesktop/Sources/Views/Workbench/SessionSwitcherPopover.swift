import SwiftUI
import WatchtowerCore

/// The session switcher's popover (board #251, variant H): find a session
/// by title or `#id`, the workbench's sessions in the panel's order with
/// their ⌘N, the current one highlighted; a new session; the panel back.
struct SessionSwitcherPopover: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let currentID: Int64?
    let onSelect: (Int64) -> Void
    let onNewSession: () -> Void
    let onShowPanel: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Find session", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            Text("SESSIONS · \(project.name.uppercased())")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            list
            Divider()
            Button(action: onNewSession) {
                shortcutLabel("New Session", systemImage: "plus", keys: "⌘T")
            }
            .buttonStyle(.borderless)
            Button(action: onShowPanel) {
                shortcutLabel("Show Sessions Panel", systemImage: "sidebar.leading", keys: "⌥⌘S")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .frame(width: 420)
        .task {
            searchFocused = true
            await vm.loadSessions(projectID: project.id)
        }
    }

    @ViewBuilder
    private var list: some View {
        if let error = vm.sessionLoadErrors[project.id] {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        let rows = SessionSwitcherPresentation.matching(
            vm.sessionRows(vm.orderedSessions(projectID: project.id)), query: query
        )
        if rows.isEmpty {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No session matches.").font(.caption).foregroundStyle(.secondary)
            } else if vm.terminalSessions[project.id] != nil, vm.sessionLoadErrors[project.id] == nil {
                // Not while the first read is in flight, nor over its error.
                Text("No sessions yet.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        SessionSwitcherRow(row: row, isCurrent: row.id == currentID) { onSelect(row.id) }
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcutLabel(_ title: String, systemImage: String, keys: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 4)
            Text(keys).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// One session: its dot, title, `#id` badge, state caption and ⌘N; the
/// current one highlighted.
struct SessionSwitcherRow: View {
    let row: SessionSwitcherPresentation.Row
    let isCurrent: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                SessionLiveDot(state: row.state)
                    .frame(width: 12)
                Text(row.session.title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let badge = row.badge {
                    WorkbenchCapsuleBadge(text: badge)
                }
                Spacer(minLength: 4)
                if let caption = row.caption {
                    // A live caption repeats the dot's label for VoiceOver.
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(row.state.isLive)
                }
                if let shortcut = row.shortcut {
                    Text("⌘\(shortcut)").font(.caption2).foregroundStyle(.secondary).fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isCurrent ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.session.title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
