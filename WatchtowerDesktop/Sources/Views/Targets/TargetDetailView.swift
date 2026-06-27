import SwiftUI

struct TargetDetailView: View {
    let target: Target
    let viewModel: TargetsViewModel
    var onClose: (() -> Void)?
    @Environment(AppState.self) private var appState

    @State private var selectedTab: Tab = .details
    @State private var editingIntent: String = ""
    @State private var editingBlocking: String = ""
    @State private var editingBallOn: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()
    @State private var showDuePopover = false
    @State private var editingBallOnField = false
    @State private var editingBlockingField = false
    @State private var showSnoozePopover = false
    @State private var snoozeCustomDate = Date()
    @State private var newSubItemText: String = ""
    @State private var editingSubItemIndex: Int?
    @State private var editingSubItemText: String = ""
    @State private var subItemDueDateIndex: Int?
    @State private var subItemDueDate: Date = Date()
    @State private var promotingSubItem: PromotingSubItemContext?
    @State private var newNoteText: String = ""
    @State private var jiraIssue: JiraIssue?
    @State private var jiraConnected = false
    @State private var jiraSiteURL: String?
    @State private var links: [TargetLink] = []
    @State private var parentTarget: Target?
    @State private var childTargets: [Target] = []
    @State private var showSuggestLinksSheet = false
    @State private var showDeleteConfirm = false
    @State private var suggestedLinks: SuggestedLinksResult?
    @State private var isSuggestingLinks = false
    @State private var suggestLinksError: String?
    @State private var chatVM: TargetChatViewModel?
    @State private var observerVM: ObserverTimelineViewModel?
    @State private var nextStep: TargetNextStep?
    @State private var isGeneratingNextStep = false
    @State private var nextStepError: String?
    @State private var assistantInput: String = ""
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case intent
    }

    enum Tab: String, CaseIterable {
        case details = "Details"
        case links = "Links"
        case activity = "Activity"
        case assistant = "Assistant"
    }

    /// Identifies a sub-item the user is currently promoting via `PromoteSubItemSheet`.
    /// Uses a fresh UUID per presentation so SwiftUI's `.sheet(item:)` always
    /// re-presents — even when the user dismisses and immediately reopens at
    /// the same sub-item position.
    struct PromotingSubItemContext: Identifiable {
        let id = UUID()
        let index: Int
        let item: TargetSubItem
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
                Spacer()
                Menu {
                    Button("Delete…", role: .destructive) {
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.trailing, 8)
                if let onClose {
                    Button { onClose() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 12)
                }
            }
            .padding(.horizontal, 4)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .details:
                        detailsTab
                    case .links:
                        linksTab
                    case .activity:
                        activityTab
                    case .assistant:
                        if let chatVM {
                            TargetChatSection(chatVM: chatVM)
                                .frame(minHeight: 320)
                        } else {
                            Color.clear.onAppear {
                                if let dbManager = appState.databaseManager {
                                    chatVM = TargetChatViewModel(
                                        target: target, viewModel: viewModel, dbManager: dbManager
                                    )
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .onAppear {
            jiraConnected = JiraQueries.isConnected()
            jiraSiteURL = JiraConfigHelper.readSiteURL()
            syncState()
            loadJiraIssue()
            loadLinks()
            loadHierarchy()
            syncNextStep()
            if observerVM == nil, let runner = ProcessCLIRunner.makeDefault(),
               let dbManager = appState.databaseManager {
                observerVM = ObserverTimelineViewModel(
                    target: target,
                    dbManager: dbManager,
                    targetsViewModel: viewModel,
                    observeService: TargetObserveService(runner: runner)
                )
                observerVM?.start()
            }
        }
        .onChange(of: target.id) {
            syncState()
            loadJiraIssue()
            loadLinks()
            loadHierarchy()
            syncNextStep()
            observerVM = nil
            if let runner = ProcessCLIRunner.makeDefault(),
               let dbManager = appState.databaseManager {
                observerVM = ObserverTimelineViewModel(
                    target: target,
                    dbManager: dbManager,
                    targetsViewModel: viewModel,
                    observeService: TargetObserveService(runner: runner)
                )
                observerVM?.start()
            }
        }
        .onChange(of: target.nextStep) {
            // Pick up suggestions written by the daemon's next-step phase.
            if !isGeneratingNextStep { nextStep = target.decodedNextStep }
        }
        .onChange(of: focusedField) { oldValue, _ in
            switch oldValue {
            case .intent: commitIntent()
            case .none: break
            }
        }
        .sheet(isPresented: $showSuggestLinksSheet) {
            if let suggestedLinks {
                SuggestLinksSheet(
                    targetID: target.id,
                    suggestions: suggestedLinks
                )
            }
        }
        .sheet(item: $promotingSubItem) { ctx in
            let prefill = TargetPrefillBuilder.fromSubItem(
                parent: target,
                subItem: ctx.item,
                index: ctx.index
            )
            PromoteSubItemSheet(
                parent: target,
                subItem: ctx.item,
                subItemIndex: ctx.index,
                viewModel: viewModel,
                prefilledIntent: prefill.intent
            )
        }
        .confirmationDialog(
            {
                let label = target.text.count > 60
                    ? String(target.text.prefix(60)) + "…"
                    : target.text
                return "Delete \"\(label)\"?"
            }(),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                viewModel.deleteTarget(target)
                onClose?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button(tab.rawValue) {
            selectedTab = tab
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
    }

    private func syncState() {
        editingIntent = target.intent
        editingBlocking = target.blocking
        editingBallOn = target.ballOn
        hasDueDate = !target.dueDate.isEmpty
        if let date = Target.parseDueDate(target.dueDate) {
            dueDate = date
        }
    }

    // MARK: - Details Tab

    private var detailsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            breadcrumbSection
            heroSection
            statusBadgesRow
            nextStepCard
            if let observerVM {
                ObserverTimelineView(viewModel: observerVM)
            }
            metadataGrid
            checklistSection
            intentSection
            hierarchySection
            notesSection
            jiraIssueSection
            assistantInlineInput
            footerActions
        }
    }

    // MARK: - Breadcrumb

    @ViewBuilder
    private var breadcrumbSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.left")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let parent = parentTarget {
                Button {
                    appState.pendingTargetID = parent.id
                } label: {
                    Text(parent.text)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                breadcrumbDot
            }
            Text(levelDisplay)
            if !periodShort.isEmpty {
                breadcrumbDot
                Text(periodShort)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var breadcrumbDot: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    // MARK: - Hero (progress ring + title)

    private var heroSection: some View {
        HStack(alignment: .top, spacing: 16) {
            progressRing
            VStack(alignment: .leading, spacing: 6) {
                titleText
            }
            Spacer(minLength: 0)
        }
    }

    /// Ring fill fraction: prefer checklist completion when sub-items exist,
    /// else fall back to the target's computed progress.
    private var ringFraction: Double {
        let items = target.decodedSubItems
        if !items.isEmpty {
            return Double(items.filter(\.done).count) / Double(items.count)
        }
        return target.progress
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.001, ringFraction))
                .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(ringFraction * 100))%")
                    .font(.system(size: 15, weight: .bold))
                if let progress = target.subItemsProgress {
                    Text(progress)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 64, height: 64)
    }

    /// Title with the trailing parenthetical (if any) dimmed, matching the design.
    private var titleText: some View {
        let full = target.text
        let primary: String
        let secondary: String
        if let range = full.range(of: " ("), full.hasSuffix(")") {
            primary = String(full[full.startIndex..<range.lowerBound])
            secondary = String(full[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            primary = full
            secondary = ""
        }
        return (
            Text(primary).foregroundStyle(.primary)
            + Text(secondary.isEmpty ? "" : " \(secondary)").foregroundStyle(.secondary)
        )
        .font(.title2)
        .fontWeight(.bold)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Status badges

    private var statusBadgesRow: some View {
        HStack(spacing: 8) {
            ForEach(["todo", "in_progress", "blocked", "done"], id: \.self) { status in
                statusBadge(status)
            }
            Spacer(minLength: 0)
        }
    }

    private func statusBadge(_ status: String) -> some View {
        let isSelected = target.status == status
        let color = statusButtonColor(status)
        return Button {
            viewModel.updateStatus(target, to: status)
        } label: {
            Text(statusDisplayName(status))
                .font(.callout)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? color : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? color.opacity(0.16) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isSelected ? color.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Next Step Card

    @ViewBuilder
    private var nextStepCard: some View {
        if let ns = nextStep {
            nextStepCardBody(ns)
        } else if isGeneratingNextStep {
            nextStepLoadingCard
        } else if target.isActive {
            nextStepEmptyCard
        }
    }

    private func nextStepCardBody(_ ns: TargetNextStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.purple.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    Text("NEXT STEP")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                }
                Spacer()
                if let label = urgencyLabel(ns) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await generateNextStep() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Regenerate next step")
            }

            Text(ns.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if !ns.rationale.isEmpty {
                Text(ns.rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !ns.actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(ns.actions.enumerated()), id: \.offset) { index, action in
                        nextStepActionButton(action, index: index)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.purple.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func nextStepActionButton(_ action: TargetNextStepAction, index: Int) -> some View {
        Button {
            handleNextStepAction(action)
        } label: {
            Text(action.label)
                .font(.callout)
                .fontWeight(index == 0 ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .modifier(NextStepButtonStyle(index: index))
    }

    private var nextStepLoadingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Thinking about the next step…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var nextStepEmptyCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Suggest a next step")
                    .font(.callout)
                    .fontWeight(.medium)
                if let nextStepError {
                    Text(nextStepError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button("Generate") {
                Task { await generateNextStep() }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.purple.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Metadata grid

    private var metadataGrid: some View {
        HStack(alignment: .top, spacing: 0) {
            metadataCell(label: "PRIORITY") { priorityMenu }
            metadataDivider
            metadataCell(label: "DUE") { dueValue }
            metadataDivider
            metadataCell(label: "BALL ON") { ballOnValue }
            metadataDivider
            metadataCell(label: "BLOCKING") { blockingValue }
        }
        .padding(.vertical, 12)
        .overlay(Divider(), alignment: .top)
        .overlay(Divider(), alignment: .bottom)
    }

    private func metadataCell<Content: View>(
        label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadataDivider: some View {
        Divider().frame(height: 32)
    }

    @ViewBuilder
    private var dueValue: some View {
        Button {
            showDuePopover = true
        } label: {
            Text(target.dueDateFormatted ?? "—")
                .font(.callout)
                .foregroundStyle(target.isOverdue ? Color.red : (target.dueDate.isEmpty ? Color.secondary : Color.orange))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDuePopover) { duePopover }
    }

    @ViewBuilder
    private var ballOnValue: some View {
        if editingBallOnField {
            TextField("Who?", text: $editingBallOn)
                .font(.callout)
                .textFieldStyle(.plain)
                .onSubmit { commitBallOn(); editingBallOnField = false }
        } else {
            Button {
                editingBallOnField = true
            } label: {
                if target.ballOn.isEmpty {
                    Text("—").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 5) {
                        avatarCircle(target.ballOn)
                        Text(target.ballOn).font(.callout)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var blockingValue: some View {
        if editingBlockingField {
            TextField("Blocking?", text: $editingBlocking)
                .font(.callout)
                .textFieldStyle(.plain)
                .onSubmit { commitBlocking(); editingBlockingField = false }
        } else {
            Button {
                editingBlockingField = true
            } label: {
                Text(target.blocking.isEmpty ? "—" : target.blocking)
                    .font(.callout)
                    .foregroundStyle(target.blocking.isEmpty ? Color.secondary : Color.red)
            }
            .buttonStyle(.plain)
        }
    }

    private func avatarCircle(_ name: String) -> some View {
        let initial = name.first.map { String($0).uppercased() } ?? "?"
        return Text(initial)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Color.blue, in: Circle())
    }

    private var duePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Has due date", isOn: $hasDueDate)
                .onChange(of: hasDueDate) { _, newValue in
                    if newValue { commitDueDate() } else { viewModel.updateDueDate(target, to: "") }
                }
            if hasDueDate {
                DatePicker("", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .onChange(of: dueDate) { _, _ in commitDueDate() }
            }
        }
        .padding()
        .frame(width: 240)
    }

    // MARK: - Checklist (2 columns, "stuck" badge on overdue)

    @ViewBuilder
    private var checklistSection: some View {
        let items = target.decodedSubItems
        VStack(alignment: .leading, spacing: 10) {
            Text("CHECKLIST")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .tracking(0.5)

            if !items.isEmpty {
                let columns = [GridItem(.flexible(), alignment: .leading),
                               GridItem(.flexible(), alignment: .leading)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        checklistRow(index: index, item: item)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField("Add item…", text: $newSubItemText)
                    .font(.callout)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        viewModel.addSubItem(target, text: newSubItemText)
                        newSubItemText = ""
                    }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func checklistRow(index: Int, item: TargetSubItem) -> some View {
        HStack(spacing: 8) {
            Button {
                viewModel.toggleSubItem(target, index: index)
            } label: {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.done ? .green : .secondary)
            }
            .buttonStyle(.plain)

            if editingSubItemIndex == index {
                TextField("Sub-item", text: $editingSubItemText)
                    .font(.callout)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        viewModel.editSubItem(target, index: index, newText: editingSubItemText)
                        editingSubItemIndex = nil
                    }
                    .onExitCommand { editingSubItemIndex = nil }
            } else {
                Text(item.text)
                    .font(.callout)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .lineLimit(1)
                    .onTapGesture {
                        editingSubItemIndex = index
                        editingSubItemText = item.text
                    }
            }

            if item.isOverdue {
                Text("stuck")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Convert to sub-target") {
                promotingSubItem = PromotingSubItemContext(index: index, item: item)
            }
            Button("Remove", role: .destructive) {
                viewModel.removeSubItem(target, index: index)
            }
        }
    }

    // MARK: - Assistant inline input

    private var assistantInlineInput: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.purple)
                .padding(.bottom, 14)
            // Reuse the chat composer so the inline input is a real auto-expanding
            // text area (Enter sends, Shift+Enter inserts a newline) — consistent
            // with the Assistant tab instead of a single-line field.
            ChatInput(
                text: $assistantInput,
                isStreaming: false,
                onSend: { submitAssistantInput() },
                placeholder: "Ask the assistant about this target…"
            )
        }
    }

    // MARK: - Footer actions

    private var footerActions: some View {
        HStack(spacing: 8) {
            if target.isActive {
                Button {
                    viewModel.dismiss(target)
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Button {
                    showSnoozePopover = true
                } label: {
                    Label("Snooze", systemImage: "moon")
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showSnoozePopover) { snoozePopover }
            }

            Spacer()

            if let dbManager = appState.databaseManager {
                FeedbackButtons(
                    entityType: "target",
                    entityID: String(target.id),
                    dbManager: dbManager
                )
            }
        }
    }

    // MARK: - Next-step logic

    /// Loads the persisted next-step for the current target and generates one
    /// only when none has ever been stored (and the target is active).
    ///
    /// The suggestion is generated once and then reused: subsequent regeneration
    /// is on demand (the refresh button / a "Different plan" action). We read the
    /// stored value straight from the DB rather than trusting `target.nextStep`,
    /// because the CLI writes it from another process and GRDB's observation does
    /// not surface cross-process writes onto the in-memory `target`.
    private func syncNextStep() {
        nextStepError = nil
        if let stored = storedNextStep() {
            nextStep = stored
            return
        }
        nextStep = nil
        if target.isActive && !isGeneratingNextStep {
            Task { await generateNextStep() }
        }
    }

    /// Reads the authoritative stored next-step for this target from the DB,
    /// falling back to the (possibly stale) value carried on `target`.
    private func storedNextStep() -> TargetNextStep? {
        guard let dbManager = appState.databaseManager else { return target.decodedNextStep }
        let fresh = try? dbManager.dbPool.read { db in
            try TargetQueries.fetchByID(db, id: target.id)
        }
        return (fresh ?? nil)?.decodedNextStep ?? target.decodedNextStep
    }

    private func generateNextStep() async {
        guard let runner = ProcessCLIRunner.makeDefault() else {
            nextStepError = "watchtower CLI not found in PATH"
            return
        }
        isGeneratingNextStep = true
        nextStepError = nil
        defer { isGeneratingNextStep = false }
        do {
            let service = TargetNextStepService(runner: runner)
            nextStep = try await service.generate(targetID: target.id)
        } catch {
            nextStepError = "Couldn't generate a next step"
        }
    }

    private func handleNextStepAction(_ action: TargetNextStepAction) {
        switch action.kind {
        case "assistant":
            sendToAssistant(action.prompt ?? action.label)
        case "open_links":
            selectedTab = .links
        case "mark_done":
            viewModel.markDone(target)
        case "dismiss":
            viewModel.dismiss(target)
        default:
            break
        }
    }

    private func submitAssistantInput() {
        let text = assistantInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        assistantInput = ""
        sendToAssistant(text)
    }

    /// Routes a prompt into the target assistant chat, creating the view model
    /// if needed, and switches to the Assistant tab so the user sees the reply.
    private func sendToAssistant(_ prompt: String) {
        if chatVM == nil, let dbManager = appState.databaseManager {
            chatVM = TargetChatViewModel(target: target, viewModel: viewModel, dbManager: dbManager)
        }
        guard let chatVM else { return }
        selectedTab = .assistant
        chatVM.inputText = prompt
        chatVM.send()
    }

    private func urgencyLabel(_ ns: TargetNextStep) -> String? {
        let base: String?
        switch ns.urgency {
        case "deadline": base = "by deadline"
        case "blocked":  base = "blocked"
        case "stale":    base = "stale"
        default:         base = nil
        }
        switch (base, ns.urgencyDetail.isEmpty) {
        case (let b?, false): return "\(b) · \(ns.urgencyDetail)"
        case (let b?, true):  return b
        case (nil, false):    return ns.urgencyDetail
        default:              return nil
        }
    }

    // MARK: - Intent

    private var intentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Intent")
                .font(.headline)
            ZStack(alignment: .topLeading) {
                if editingIntent.isEmpty {
                    Text("Why this target matters…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $editingIntent)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 56, maxHeight: 160)
                    .focused($focusedField, equals: .intent)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Hierarchy (sub-targets)

    @ViewBuilder
    private var hierarchySection: some View {
        if !childTargets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dependencies")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                if !childTargets.isEmpty {
                    Text("Sub-targets (\(childTargets.count))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    ForEach(childTargets) { child in
                        hierarchyRow(child, icon: "arrow.turn.down.right")
                    }
                }
            }
        }
    }

    private func hierarchyRow(_ item: Target, icon: String) -> some View {
        Button {
            appState.pendingTargetID = item.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Circle()
                    .fill(item.isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(item.text)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text(item.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func loadHierarchy() {
        guard let dbManager = appState.databaseManager else {
            parentTarget = nil
            childTargets = []
            return
        }
        do {
            try dbManager.dbPool.read { db in
                parentTarget = try target.parentId.flatMap { try TargetQueries.fetchByID(db, id: $0) }
                childTargets = try TargetQueries.fetchAll(
                    db, filter: TargetFilter(includeDone: true, parentID: target.id)
                )
            }
        } catch {
            parentTarget = nil
            childTargets = []
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)

            let notes = target.decodedNotes
            if notes.isEmpty {
                Text("No notes yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.text)
                                .font(.callout)
                            if let date = note.createdDate {
                                Text(date, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button {
                            viewModel.removeNote(target, index: index)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                    if index < notes.count - 1 { Divider() }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField("Add note...", text: $newNoteText)
                    .font(.callout)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        viewModel.addNote(target, text: newNoteText)
                        newNoteText = ""
                    }
            }
        }
    }

    // MARK: - Snooze Popover

    private var snoozePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Snooze until")
                .font(.headline)
                .padding(.bottom, 4)
            Button("Tomorrow") { snoozeFor(days: 1) }
            Button("In 3 days") { snoozeFor(days: 3) }
            Button("In a week") { snoozeFor(days: 7) }
            Divider()
            DatePicker("Pick date", selection: $snoozeCustomDate, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
            Button("Snooze to selected date") {
                viewModel.snooze(target, until: snoozeCustomDate)
                showSnoozePopover = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 220)
    }

    // MARK: - Links Tab

    private var linksTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            let inbound = links.filter { $0.targetTargetId == target.id }
            let outbound = links.filter { $0.sourceTargetId == target.id }

            if inbound.isEmpty && outbound.isEmpty {
                Text("No links yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !inbound.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inbound")
                        .font(.headline)
                    ForEach(inbound) { link in
                        linkRow(link)
                    }
                }
            }

            if !outbound.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Outbound")
                        .font(.headline)
                    ForEach(outbound) { link in
                        linkRow(link)
                    }
                }
            }

            HStack {
                Button {
                    Task { await runSuggestLinks() }
                } label: {
                    if isSuggestingLinks {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Suggesting…")
                        }
                    } else {
                        Label("Suggest links", systemImage: "sparkles")
                    }
                }
                .disabled(isSuggestingLinks)
                if let suggestLinksError {
                    Text(suggestLinksError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func linkRow(_ link: TargetLink) -> some View {
        HStack(spacing: 8) {
            Text(link.relation.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(relationColor(link.relation), in: Capsule())

            if link.isExternalLink {
                if let url = externalURL(link.externalRef) {
                    Link(link.externalRef, destination: url)
                        .font(.callout)
                } else {
                    Text(link.externalRef)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let peerID = link.targetTargetId == target.id ? link.sourceTargetId : link.targetTargetId {
                Text("Target #\(peerID)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if link.isAICreated {
                if let conf = link.confidence {
                    Text("\(Int(conf * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Activity Tab

    private var activityTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Progress")
                    .font(.headline)
                ProgressView(value: target.progress)
                    .tint(.green)
                Text("\(Int(target.progress * 100))% complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !target.sourceType.isEmpty && target.sourceType != "manual" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source")
                        .font(.headline)
                    Text("\(target.sourceType.capitalized) \(target.sourceID)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Created")
                    .font(.headline)
                Text(target.createdDate, style: .date)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Updated")
                    .font(.headline)
                Text(target.updatedDate, style: .relative)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            let tags = target.decodedTags
            if !tags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tags")
                        .font(.headline)
                    FlowLayout(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.blue.opacity(0.1), in: Capsule())
                        }
                    }
                }
            }

            if let dbManager = appState.databaseManager {
                FeedbackButtons(
                    entityType: "target",
                    entityID: String(target.id),
                    dbManager: dbManager
                )
            }
        }
    }

    // MARK: - Jira Issue

    @ViewBuilder
    private var jiraIssueSection: some View {
        if target.sourceType == "jira", let issue = jiraIssue {
            VStack(alignment: .leading, spacing: 8) {
                Text("Jira Issue")
                    .font(.headline)

                Button {
                    openJiraIssue()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full")
                            .foregroundStyle(.blue)
                        Text(issue.key)
                            .font(.callout)
                            .fontWeight(.medium)
                            .foregroundStyle(.blue)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                Text(issue.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Priority Menu

    private var levelDisplay: String {
        target.level.capitalized
            + (target.level == "custom" && !target.customLabel.isEmpty ? " (\(target.customLabel))" : "")
    }

    /// Short period hint for the breadcrumb (the period's month, e.g. "July").
    private var periodShort: String {
        guard let date = Target.parseDueDate(target.periodStart) else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL"
        return fmt.string(from: date)
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(["high", "medium", "low"], id: \.self) { p in
                Button {
                    viewModel.updatePriority(target, to: p)
                } label: {
                    HStack {
                        Text(p.capitalized)
                        if target.priority == p { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(priorityColor)
                    .frame(width: 8, height: 8)
                Text(target.priority.capitalized)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(priorityColor.opacity(0.12), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Helpers

    private var priorityColor: Color {
        switch target.priority {
        case "high": return .red
        case "medium": return .orange
        case "low": return .blue
        default: return .orange
        }
    }

    private func statusDisplayName(_ status: String) -> String {
        switch status {
        case "todo": return "To Do"
        case "in_progress": return "In Progress"
        case "blocked": return "Blocked"
        case "done": return "Done"
        case "dismissed": return "Dismissed"
        case "snoozed": return "Snoozed"
        default: return status.capitalized
        }
    }

    private func statusButtonColor(_ status: String) -> Color {
        switch status {
        case "todo": return .secondary
        case "in_progress": return .blue
        case "blocked": return .red
        case "done": return .green
        case "dismissed": return .gray
        case "snoozed": return .purple
        default: return .secondary
        }
    }

    private func relationColor(_ relation: String) -> Color {
        switch relation {
        case "contributes_to": return .green
        case "blocks": return .red
        case "related": return .blue
        case "duplicates": return .orange
        default: return .gray
        }
    }

    private func externalURL(_ ref: String) -> URL? {
        if ref.hasPrefix("jira:") {
            guard let site = jiraSiteURL else { return nil }
            let key = String(ref.dropFirst(5))
            return URL(string: "\(site)/browse/\(key)")
        }
        if ref.hasPrefix("slack:") {
            let parts = ref.dropFirst(6).split(separator: ":")
            guard parts.count >= 2 else { return nil }
            return URL(string: "https://slack.com/archives/\(parts[0])/p\(parts[1].replacingOccurrences(of: ".", with: ""))")
        }
        return nil
    }

    private func loadJiraIssue() {
        if target.sourceType == "jira" {
            jiraIssue = viewModel.fetchJiraIssue(key: target.sourceID)
        } else {
            jiraIssue = nil
        }
    }

    private func loadLinks() {
        links = viewModel.fetchLinks(for: target.id)
    }

    private func openJiraIssue() {
        guard let siteURL = jiraSiteURL, !siteURL.isEmpty else { return }
        let urlString = "\(siteURL)/browse/\(target.sourceID)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func snoozeFor(days: Int) {
        let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        viewModel.snooze(target, until: date)
        showSnoozePopover = false
    }

    // MARK: - Commit Helpers

    private func commitIntent() {
        let trimmed = editingIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != target.intent else { return }
        viewModel.updateIntent(target, to: trimmed)
    }

    private func commitDueDate() {
        let dateStr = Target.formatDueDate(dueDate)
        guard dateStr != target.dueDate else { return }
        viewModel.updateDueDate(target, to: dateStr)
    }

    private func commitBlocking() {
        let trimmed = editingBlocking.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != target.blocking else { return }
        viewModel.updateBlocking(target, to: trimmed)
    }

    private func commitBallOn() {
        let trimmed = editingBallOn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != target.ballOn else { return }
        viewModel.updateBallOn(target, to: trimmed)
    }

    // MARK: - Actions

    private func runSuggestLinks() async {
        guard let runner = ProcessCLIRunner.makeDefault() else {
            suggestLinksError = "watchtower CLI not found in PATH"
            return
        }
        isSuggestingLinks = true
        suggestLinksError = nil
        defer { isSuggestingLinks = false }
        do {
            let service = TargetSuggestLinksService(runner: runner)
            let result = try await service.suggest(targetID: target.id)
            if result.parentID == nil && result.secondaryLinks.isEmpty {
                suggestLinksError = "AI had no suggestions"
                return
            }
            suggestedLinks = result
            showSuggestLinksSheet = true
        } catch {
            suggestLinksError = "Suggest-links failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Next-step button styling

/// Styles a next-step action button by position: 0 = primary (filled accent),
/// 1 = secondary (bordered), 2+ = ghost (plain text).
private struct NextStepButtonStyle: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        switch index {
        case 0:
            content
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
        case 1:
            content
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        default:
            content
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
        }
    }
}
