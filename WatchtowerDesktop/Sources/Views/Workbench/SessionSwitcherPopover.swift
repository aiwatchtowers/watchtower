import SwiftUI
import WatchtowerCore

/// The session switcher's popover (board #251, variant H): find a session
/// by title or `#id`, the workbench's sessions in the panel's order with
/// their ⌘N, the current one highlighted; a new session of each agent; the
/// panel back.
struct SessionSwitcherPopover: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let currentID: Int64?
    let onSelect: (Int64) -> Void
    let onNewSession: (AgentKind) -> Void
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
            // One entry per agent; ⌘T is the default agent's.
            ForEach(AgentChoicePresentation.newSessionAgentChoices { vm.agentAvailable($0, projectID: project.id) }) { choice in
                Button { onNewSession(choice.agent) } label: {
                    shortcutLabel(choice.title, systemImage: "plus", keys: choice.agent == vm.defaultAgent ? "⌘T" : "")
                }
                .buttonStyle(.borderless)
                .disabled(!choice.isAvailable)
                .help(choice.hint ?? "")
            }
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
        // The panel's order (#480): its main list, then a "Finished"
        // divider and every finished session, folded in the panel or not.
        let sections = vm.panelSections(projectID: project.id)
        let rows = SessionSwitcherPresentation.matching(sections.main, query: query)
        let finished = SessionSwitcherPresentation.matching(sections.groupRows, query: query)
        if rows.isEmpty, finished.isEmpty {
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
                    if !finished.isEmpty {
                        SessionSwitcherFinishedDivider()
                        ForEach(finished) { row in
                            SessionSwitcherRow(row: row, isCurrent: row.id == currentID) { onSelect(row.id) }
                        }
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

/// The "Finished" divider above the finished sessions (#480).
struct SessionSwitcherFinishedDivider: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Finished")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            VStack { Divider() }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One session: its dot, title, `#id` badge, state label and ⌘N; the
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
                    // The label reads the state out.
                    .accessibilityHidden(row.caption != nil)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.session.title)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let place = row.place { SessionPlaceLine(label: place) }
                }
                if let badge = row.badge {
                    WorkbenchCapsuleBadge(text: badge)
                }
                if let tag = row.agentTag { AgentTag(text: tag) }
                Spacer(minLength: 4)
                if let caption = row.caption {
                    SessionStateLabel(state: row.state, caption: caption).fixedSize()
                }
                if let shortcut = row.shortcut {
                    Text("⌘\(shortcut)").font(.caption2).foregroundStyle(.secondary).fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 30)
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
