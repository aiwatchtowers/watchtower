import SwiftUI
import WatchtowerCore

/// The open board target in a panel on the board's trailing side (spec
/// 2026-10-06 Part 3, board #255): one view, two shapes. A target without
/// children is a task (status menu, Work on It); one with children is a
/// group (its status follows its sub-tasks, an "N of M done" summary and a
/// SUB-TASKS tree). The mode is derived from the node, never stored. The
/// header stays put; the body scrolls; the comment composer is pinned under
/// it.
struct WorkbenchTargetPanel: View {
    let vm: WorkbenchBoardViewModel
    let node: WorkbenchBoardNode
    /// The board drift findings on this target (PROJ-07), shown as chips.
    let findings: [WorkbenchDriftFinding]
    /// Owned by the board view; reset to the open target's title on every
    /// switch. Comment drafts are per target in the view model.
    @Binding var titleDraft: String
    /// `WorkbenchesViewModel.showAsk`: an Asks row opens the ask drawer.
    let onShowAsk: (Int64, Int64) async -> Bool
    /// Why an ask did not open (the asks' `loadErrors`); nil = it is gone.
    let askOpenFailure: () -> String?
    /// Open group: enters the group as the board scope (spec 2026-10-06
    /// Part 4).
    let onOpenGroup: (Int) -> Void
    let onClose: () -> Void

    private enum Mode {
        case task
        case group
    }

    private var target: Target { node.target }
    private var mode: Mode { node.children.isEmpty ? .task : .group }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
            }
            Divider()
            WorkbenchPanelComposer(vm: vm)
        }
        .onAppear { titleDraft = target.text }
        .onChange(of: target.id) { titleDraft = target.text }
        .onChange(of: target.text) { titleDraft = target.text }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar
            if let parent = vm.selectedParent {
                parentLink(parent)
            }
            // A wrapping field: a long title shows whole. Return renames.
            TextField("Title", text: $titleDraft, axis: .vertical)
                .font(.title3.weight(.semibold))
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit { vm.rename(titleDraft) }
                .help("Edit the title; Return saves it")
            FlowLayout(spacing: 6) {
                switch mode {
                case .task: statusMenu
                case .group: groupStatus
                }
                priorityMenu
                ForEach(findings) { finding in
                    WorkbenchBoardChip(
                        text: finding.kindLabel,
                        color: finding.isConflict ? .orange : .secondary,
                        dot: true
                    )
                    .help(finding.detail)
                }
            }
            if mode == .group {
                WorkbenchGroupProgress(summary: WorkbenchGroupSummary(node, showArchived: vm.showArchived))
            } else if target.progress > 0 {
                progress
            }
            gitLinks
        }
        .padding(16)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if vm.canGoBack {
                Button { vm.back() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back")
                .accessibilityLabel("Back")
            }
            numberButton
            if mode == .group {
                WorkbenchBoardChip(text: "GROUP", color: .secondary)
            }
            Spacer(minLength: 0)
            switch mode {
            case .task:
                WorkOnTargetButton(target: target, compact: false, isVisible: true)
                    .fixedSize()
            case .group:
                Button { onOpenGroup(target.id) } label: {
                    Label("Open group", systemImage: "arrow.down.right.square")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(vm.scopeNode?.target.id == target.id)
                .help("Show only this group on the board")
            }
            moreMenu
            closeButton
        }
    }

    /// "▦ #249 Title ›": the nearest parent, opened on top of the path.
    private func parentLink(_ parent: WorkbenchBoardNode) -> some View {
        let title = WorkbenchBoardCard.title(parent.target.text)
        return Button { vm.push(parent.id) } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                Text(WorkbenchTargetNumber.label(parent.id))
                    .monospacedDigit()
                Text(title.isEmpty ? "Untitled" : title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the parent \(WorkbenchTargetNumber.label(parent.id)) in the panel")
    }

    private var moreMenu: some View {
        Menu {
            WorkbenchTargetMenu(target: target, vm: vm)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.secondary.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")
        .accessibilityLabel("Close")
    }

    /// The target's `#id` (board #207); a click copies it.
    private var numberButton: some View {
        Button { WorkbenchTargetNumber.copy(target.id) } label: {
            WorkbenchBoardChip(text: WorkbenchTargetNumber.label(target.id), color: .secondary)
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Copy the target number")
    }

    /// Read-only: the agent's tools set a task's progress.
    private var progress: some View {
        let value = min(max(target.progress, 0), 1)
        return HStack(spacing: 6) {
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(value >= 1 ? .green : .accentColor)
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Progress")
    }

    /// Branch and PR, read-only (the agent links them); an empty one hides.
    @ViewBuilder
    private var gitLinks: some View {
        if !target.branch.isEmpty || !target.pr.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !target.branch.isEmpty {
                    Label(target.branch, systemImage: "arrow.triangle.branch")
                }
                if !target.pr.isEmpty {
                    Label("PR \(target.pr)", systemImage: "arrow.triangle.pull")
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
    }

    private var statusMenu: some View {
        Menu {
            ForEach(WorkbenchBoardCard.editableStatuses, id: \.self) { status in
                Toggle(WorkbenchBoardCard.statusLabel(status), isOn: Binding(
                    get: { target.status == status },
                    set: { if $0 { vm.setStatus(status) } }
                ))
            }
        } label: {
            WorkbenchDetailMenuLabel(
                text: WorkbenchBoardCard.statusLabel(target.status),
                systemImage: target.statusIcon,
                color: WorkbenchBoardColors.status(target.statusColor)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Status")
    }

    /// A group's status follows its children (PROJ-05): never a menu here.
    private var groupStatus: some View {
        WorkbenchDetailMenuLabel(
            text: "\(WorkbenchBoardCard.statusLabel(target.status)) · from sub-tasks",
            systemImage: target.statusIcon,
            color: WorkbenchBoardColors.status(target.statusColor),
            isMenu: false
        )
        .fixedSize()
        .help("A group's status follows its sub-tasks")
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(WorkbenchBoardCard.editablePriorities, id: \.self) { priority in
                Toggle(priority.capitalized, isOn: Binding(
                    get: { target.priority == priority },
                    set: { if $0 { vm.setPriority(priority) } }
                ))
            }
        } label: {
            WorkbenchDetailMenuLabel(
                text: target.priority.capitalized,
                systemImage: "flag.fill",
                color: WorkbenchBoardColors.priority(target.priority)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Priority")
    }

    // MARK: - Body

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            WorkbenchPanelDescription(targetID: target.id, intent: target.intent) { text, original, id in
                vm.saveIntent(text, original: original, for: id)
            }
            if mode == .group {
                WorkbenchGroupSubtasks(group: node, showArchived: vm.showArchived) { vm.push($0) }
            }
            if !vm.selectedImages.isEmpty {
                WorkbenchTargetImagesSection(images: vm.selectedImages)
            }
            if !vm.selectedAsks.isEmpty {
                WorkbenchPanelAsks(vm: vm, onShowAsk: onShowAsk, failure: askOpenFailure)
            }
            WorkbenchPanelActivity(vm: vm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
