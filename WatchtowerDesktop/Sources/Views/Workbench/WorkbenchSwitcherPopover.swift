import SwiftUI
import WatchtowerCore

/// The workbench switcher's popover (board #250, variant F): find a
/// workbench by name or folder, most recently worked on first, the current
/// one checked; Open Folder… for another one; back to the list of all of them.
struct WorkbenchSwitcherPopover: View {
    @Bindable var vm: WorkbenchesViewModel
    let currentID: Int64
    let onSelect: (Int64) -> Void
    let onOpenFolder: () -> Void
    let onShowAll: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Find workbench", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            Text("RECENT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            list
            Divider()
            Button(action: onOpenFolder) {
                Label("Open Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .disabled(vm.isCreating)
            Button(action: onShowAll) {
                HStack {
                    Label("All Workbenches", systemImage: "chevron.backward")
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .frame(width: 380)
        .task {
            searchFocused = true
            await vm.loadSwitcherSummaries()
        }
    }

    @ViewBuilder
    private var list: some View {
        if let error = vm.switcherError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        let rows = WorkbenchSwitcherPresentation.matching(
            WorkbenchSwitcherPresentation.ordered(vm.switcherSummaries), query: query
        )
        if rows.isEmpty {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No workbench matches.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            let now = vm.now()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        WorkbenchSwitcherRow(
                            row: row,
                            isCurrent: row.id == currentID,
                            segments: WorkbenchSwitcherPresentation.stateSegments(
                                summary: row, newComments: row.summary.unreadAgentComments,
                                workingCount: vm.workingSessionCount(workbenchID: row.id), now: now
                            )
                        ) {
                            onSelect(row.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One workbench: the shared switcher row over the workbench's name, its
/// folder as the tooltip and its state segments.
struct WorkbenchSwitcherRow: View {
    let row: WorkbenchSwitcherSummary
    let isCurrent: Bool
    let segments: [WorkbenchSwitcherPresentation.Segment]
    let onSelect: () -> Void

    var body: some View {
        SwitcherPopoverRow(
            name: row.project.name,
            isCurrent: isCurrent,
            tooltip: row.project.folderPath,
            segments: segments.map(\.switcherSegment),
            onSelect: onSelect
        )
    }
}
