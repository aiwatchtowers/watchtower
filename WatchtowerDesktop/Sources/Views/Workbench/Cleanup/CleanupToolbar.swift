import SwiftUI
import WatchtowerCore

/// The Clean Up screen's toolbar (spec §3.2, §4.4; nothing saved): in a
/// session's scope the **Session: “…” ✕** chip, whose ✕ widens to the whole
/// workbench; then search, kind, age, owner and **Merged only**.
struct CleanupToolbar: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let state: CleanupScreenState
    @Binding var filters: CleanupFilters
    /// The Search field took (true) or left (false) the keyboard.
    var onSearchFocus: (Bool) -> Void = { _ in }
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: Spacing.regular) {
            if case let .session(sessionID) = state.scope {
                sessionChip(sessionID)
            }
            search
            KitSegmentedPicker(title: "Kind", selection: $filters.kind, segments: [
                KitSegment(value: .all, title: "All"),
                KitSegment(value: .worktrees, title: "Worktrees"),
                KitSegment(value: .branches, title: "Branches")
            ])
            ageMenu
            ownerMenu
            toggle("Merged only", isOn: $filters.mergedOnly,
                   help: "Only what is already in the default branch")
                // Off, it still reads as a control (mockup `.toggle`).
                .segmentCapsule()
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    /// The session's chip: its ✕ widens the screen to the whole workbench
    /// and plans again (its own CLI mode).
    private func sessionChip(_ sessionID: Int64) -> some View {
        let title = vm.sessions.first { $0.id == sessionID }?.title
        return toggle(CleanupScreenModel.sessionChipText(title: title, sessionID: sessionID), isOn: Binding(
            get: { true },
            set: { if !$0 { vm.widenCleanupScope(projectID: projectID) } }
        ), help: "Show the whole workbench instead of this session")
        .disabled(!vm.canRefreshCleanup(projectID: projectID))
    }

    private var search: some View {
        SearchField(text: $filters.search, placeholder: "Search", onFocusChange: onSearchFocus)
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Spacing.small)
            .frame(width: 200)
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private static let ages: [(CleanupFilters.Age, String)] = [
        (.any, "Any age"), (.days7, "Older than 7 days"), (.days30, "Older than 30 days"), (.days90, "Older than 90 days")
    ]

    private static let owners: [(CleanupFilters.Owner, String)] = [
        (.any, "Any owner"), (.session, "A session"), (.subagent, "Subagent"),
        (.placed, "Session deleted"), (.manual, "Made by hand")
    ]

    private var ageMenu: some View {
        menu(Self.ages, selection: $filters.age, systemImage: "clock", help: "By the last commit")
    }

    private var ownerMenu: some View {
        menu(Self.owners, selection: $filters.owner, systemImage: "person", help: "Who made it")
    }

    private func menu<Value: Equatable>(
        _ options: [(Value, String)], selection: Binding<Value>, systemImage: String, help: String
    ) -> some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                let (value, title) = options[index]
                Toggle(title, isOn: Binding(
                    get: { selection.wrappedValue == value },
                    set: { if $0 { selection.wrappedValue = value } }
                ))
            }
        } label: {
            MenuLabel(text: options.first { $0.0 == selection.wrappedValue }?.1 ?? "",
                      systemImage: systemImage, color: .secondary)
        }
        // A plain button keeps the label's capsule and chevron.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }

    /// A toggle chip: accent-tinted while on.
    private func toggle(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        Toggle(isOn: isOn) {
            Label { Text(title) } icon: { EmptyView() }
        }
        .toggleStyle(SegmentedToggleStyle(showsIcon: false, isHovered: hovered == title) { inside in
            if inside { hovered = title } else if hovered == title { hovered = nil }
        })
        .fixedSize()
        .help(help)
    }
}
