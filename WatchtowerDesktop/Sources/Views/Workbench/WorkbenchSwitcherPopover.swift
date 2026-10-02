import SwiftUI
import WatchtowerCore

/// The workbench switcher's popover (board #250, variant F): find a
/// workbench by name or folder, most recently worked on first, the current
/// one checked; a new workbench; back to the list of all of them.
struct WorkbenchSwitcherPopover: View {
    @Bindable var vm: WorkbenchesViewModel
    let currentID: Int64
    let onSelect: (Int64) -> Void
    let onNewWorkbench: () -> Void
    let onShowAll: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Найти workbench", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            Text("НЕДАВНИЕ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            list
            Divider()
            Button(action: onNewWorkbench) {
                Label("Новый workbench…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(vm.isCreating)
            Button(action: onShowAll) {
                HStack {
                    Label("Все workbench", systemImage: "chevron.backward")
                    Spacer(minLength: 4)
                    Text("⌘⇧O").foregroundStyle(.secondary)
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
                Text("Ничего не найдено.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            let now = vm.now()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        let live = vm.liveSessionCount(workbenchID: row.id)
                        WorkbenchSwitcherRow(
                            row: row,
                            isCurrent: row.id == currentID,
                            segments: WorkbenchSwitcherPresentation.stateSegments(
                                summary: row, newComments: vm.newCommentCount(for: row.summary),
                                liveCount: live, now: now
                            ),
                            isLive: live > 0
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

/// One workbench: a check on the current one (the row highlighted), the
/// name over the folder, the state segments, a green dot while one of its
/// sessions runs.
struct WorkbenchSwitcherRow: View {
    let row: WorkbenchSwitcherSummary
    let isCurrent: Bool
    let segments: [WorkbenchSwitcherPresentation.Segment]
    let isLive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .opacity(isCurrent ? 1 : 0)
                    .accessibilityHidden(!isCurrent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.project.name)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(row.project.folderPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                ForEach(segments, id: \.text) { segment in
                    segmentView(segment)
                }
                if isLive {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Running")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isCurrent ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.project.folderPath)
    }

    @ViewBuilder
    private func segmentView(_ segment: WorkbenchSwitcherPresentation.Segment) -> some View {
        switch segment.tone {
        case .comments:
            Text(segment.text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.blue, in: Capsule())
        case .blocked:
            Text(segment.text).font(.caption2).foregroundStyle(.orange).lineLimit(1).fixedSize()
        case .sessions, .age:
            Text(segment.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }
}
