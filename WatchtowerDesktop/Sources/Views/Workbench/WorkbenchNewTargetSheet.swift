import SwiftUI
import WatchtowerCore

/// An open New Task sheet (board #411): where the new target goes.
struct WorkbenchNewTargetRequest: Identifiable, Equatable {
    /// Go's `workbench target add` cap, counted in Unicode scalars as Go
    /// counts runes.
    static let titleLimit = InboxCardTexts.targetTitleLimit

    let id = UUID()
    /// The parent target; nil = the top level.
    let parentID: Int?
}

/// The owner's New Task panel (AI-14 §2, after Linear's New issue): the
/// parent as a breadcrumb chip, the title and description as borderless
/// text, then the priority and column chips. Created through
/// `WorkbenchBoardViewModel.createTarget`; Create more keeps the panel open
/// for the next task with the same parent and chips.
struct WorkbenchNewTargetSheet: View {
    static let width: CGFloat = 620
    /// The description grows with its text up to this height, then scrolls.
    static let descriptionHeight: ClosedRange<CGFloat> = 60...280

    let request: WorkbenchNewTargetRequest
    let vm: WorkbenchBoardViewModel
    /// The breadcrumb's first crumb.
    let workbenchName: String

    private enum Field { case title, description }

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var intent = ""
    @State private var priority = "medium"
    /// The parent the panel creates under: the request's until the owner
    /// picks another.
    @State private var parentID: Int?
    /// The picked column's `BoardColumnSlot.key`; nil = the default (the
    /// first To Do column).
    @State private var columnKey: String?
    @State private var createMore = false
    @State private var pickingParent = false
    @FocusState private var focus: Field?

    init(request: WorkbenchNewTargetRequest, vm: WorkbenchBoardViewModel, workbenchName: String) {
        self.request = request
        self.vm = vm
        self.workbenchName = workbenchName
        _parentID = State(initialValue: request.parentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, Spacing.large)
            TextField("Task title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($focus, equals: .title)
                .onSubmit { focus = .description }
            descriptionEditor
                .padding(.top, Spacing.regular)
            HStack(spacing: Spacing.regular) {
                priorityMenu
                columnMenu
            }
            .padding(.top, Spacing.medium)
            if let error = vm.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Tone.error)
                    .textSelection(.enabled)
                    .padding(.top, Spacing.medium)
            }
            footer
                .padding(.top, Spacing.page)
        }
        .padding(Spacing.page)
        .frame(width: Self.width)
        .onAppear {
            vm.dismissError()
            focus = .title
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.regular) {
            Button { pickingParent = true } label: {
                MenuLabel(text: breadcrumb, systemImage: "square.stack.3d.up", color: .secondary)
            }
            .buttonStyle(.plain)
            .help("Where the task goes — click to pick another parent")
            .popover(isPresented: $pickingParent, arrowEdge: .bottom) {
                WorkbenchNewTargetParentPicker(vm: vm, selection: parentID) { picked in
                    parentID = picked
                    pickingParent = false
                }
                .popoverSurface()
            }
            Text(parentID == nil ? "New task" : "New sub-task")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.kitIcon(isOn: false))
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
        }
    }

    private var breadcrumb: String {
        "\(workbenchName) › \(parentID.map { Self.parentLabel($0, in: vm.roots) } ?? "Top level")"
    }

    /// `#id title` of a board target, `#id` alone for one no longer on it.
    static func parentLabel(_ id: Int, in roots: [WorkbenchBoardNode]) -> String {
        let number = WorkbenchTargetNumber.label(id)
        guard let node = WorkbenchBoardOutline.find(id, in: roots) else { return number }
        return "\(number) \(WorkbenchBoardCard.title(node.target.text))"
    }

    // MARK: - Description

    /// A borderless editor that grows with its text: an invisible copy of
    /// the text sizes it (up to `descriptionHeight`, then the editor
    /// scrolls), so Return adds a line rather than submitting.
    private var descriptionEditor: some View {
        Text(intent + "\n")
            .font(.body)
            .padding(.horizontal, Spacing.small)
            .hidden()
            .frame(
                maxWidth: .infinity,
                minHeight: Self.descriptionHeight.lowerBound,
                maxHeight: Self.descriptionHeight.upperBound,
                alignment: .topLeading
            )
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $intent)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .focused($focus, equals: .description)
                    if intent.isEmpty {
                        Text("Add description…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Spacing.small)
                            .allowsHitTesting(false)
                    }
                }
            }
    }

    // MARK: - Chips

    private var priorityMenu: some View {
        Menu {
            ForEach(WorkbenchBoardCard.editablePriorities, id: \.self) { value in
                Toggle(value.capitalized, isOn: Binding(
                    get: { priority == value },
                    set: { if $0 { priority = value } }
                ))
            }
        } label: {
            MenuLabel(text: priority.capitalized, systemImage: "flag.fill", color: Tone.priority(priority))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Priority")
    }

    /// The board's To Do and In Progress columns; a status with defined
    /// columns lists them under its name, as the side panel's status menu.
    private var columnMenu: some View {
        let columns = vm.newTargetColumns
        let current = column
        return Menu {
            ForEach(["todo", "in_progress"], id: \.self) { status in
                let slots = columns.filter { $0.status == status }
                if slots.count == 1, slots[0].columnID == nil {
                    columnToggle(slots[0], current: current)
                } else if !slots.isEmpty {
                    Section(WorkbenchBoardCard.statusLabel(status)) {
                        ForEach(slots) { columnToggle($0, current: current) }
                    }
                }
            }
        } label: {
            let status = current?.status ?? "todo"
            MenuLabel(
                text: current?.title ?? WorkbenchBoardCard.statusLabel(status),
                systemImage: Target.statusIcon(status),
                color: Tone.status(Target.statusColor(status))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Column")
    }

    private func columnToggle(_ slot: BoardColumnSlot, current: BoardColumnSlot?) -> some View {
        Toggle(slot.title, isOn: Binding(
            get: { current?.key == slot.key },
            set: { if $0 { columnKey = slot.key } }
        ))
        .help(slot.description)
    }

    /// The picked column, or the default once it left the definition (a
    /// column edited away on the Kanban meanwhile).
    private var column: BoardColumnSlot? {
        let columns = vm.newTargetColumns
        return columns.first { $0.key == columnKey } ?? columns.first
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Spacing.medium) {
            Toggle("Create more", isOn: $createMore)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Keep this panel open for the next task, with the same parent and chips")
            Spacer()
            Button("Create Task", action: create)
                .buttonStyle(.kitPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCreate)
                .help("Create the task (⌘↩)")
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canCreate: Bool {
        !trimmedTitle.isEmpty && trimmedTitle.unicodeScalars.count <= WorkbenchNewTargetRequest.titleLimit
            && !vm.isCreatingTarget
    }

    private func create() {
        guard canCreate else { return }
        let sent = (title, intent)
        let more = createMore
        Task {
            let created = await vm.createTarget(
                title: sent.0, intent: sent.1, priority: priority, parentID: parentID,
                column: column, keepOpen: more
            )
            // Create more: ready for the next one, unless the owner already
            // started typing it while this one was written, or an error
            // (a failed column write) shows about the text just sent.
            guard created, more, vm.errorMessage == nil, title == sent.0, intent == sent.1 else { return }
            title = ""
            intent = ""
            focus = .title
        }
    }
}

/// The New Task panel's parent picker: the top level, then the board's open
/// targets in board order, narrowed by the board search's rules.
private struct WorkbenchNewTargetParentPicker: View {
    static let width: CGFloat = 380
    static let listHeight: CGFloat = 300
    /// Indent per depth, capped like the board's own.
    static let maxDepth = 4

    let vm: WorkbenchBoardViewModel
    let selection: Int?
    let onPick: (Int?) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let rows = vm.newTargetParents(matching: query)
        VStack(alignment: .leading, spacing: Spacing.regular) {
            TextField("Search targets", text: $query)
                .textFieldStyle(.kit)
                .focused($searchFocused)
                .onSubmit { if let match = vm.newTargetParentPick(matching: query) { onPick(match.id) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        row(title: "Top level", depth: 0, id: nil)
                    }
                    ForEach(rows) { item in
                        row(title: WorkbenchNewTargetSheet.parentLabel(item.id, in: vm.roots), depth: item.depth, id: item.id)
                    }
                    if rows.isEmpty, !query.isEmpty {
                        Text("No open target matches.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(Spacing.regular)
                    }
                }
            }
            .frame(height: Self.listHeight)
        }
        .padding(Spacing.medium)
        .frame(width: Self.width)
        .onAppear { searchFocused = true }
    }

    private func row(title: String, depth: Int, id: Int?) -> some View {
        Button { onPick(id) } label: {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, Spacing.large * CGFloat(min(depth, Self.maxDepth)))
                .kitRow(isSelected: id == selection)
        }
        .buttonStyle(.plain)
    }
}
