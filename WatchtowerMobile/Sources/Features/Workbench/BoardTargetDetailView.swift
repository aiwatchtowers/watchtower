import SwiftUI
import WatchtowerKit

/// A board target: breadcrumb, title, status, priority and progress rows, intent,
/// branch and PR, sub-targets (with Add sub-target), sessions on it, open
/// asks, the comment threads with Reply, and the composer. The phone's
/// writes show in place until the Mac applies them. An archived target is
/// read-only.
struct BoardTargetDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let replica: WorkbenchReplicaModel
    let writer: BoardWriter
    let targetID: Int64
    @State private var draft = CommentDraft()
    /// The root a reply goes under; nil for a new comment.
    @State private var replyTo: BoardTargetDetailModel.CommentRow?
    @State private var addingSubTarget = false
    @State private var startingSession = false
    /// The session the start sheet's Open session or Open it goes to.
    @State private var openSession: SessionRoute?
    @State private var sendError: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let detail = BoardTargetDetailModel(
                targetID: targetID, snapshot: replica.snapshot, now: context.date, inFlight: writer.inFlight
            ) {
                content(detail)
            } else {
                ContentUnavailableView(
                    "Target not found",
                    systemImage: "circle.dashed",
                    description: Text("It is no longer on the board.")
                )
            }
        }
        .navigationTitle("#\(targetID)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: Spacing.small) {
                    if let title = replica.snapshot.targets.first(where: { $0.id == targetID })?.text {
                        Text(title).font(.headline).lineLimit(1)
                    }
                    Text("#\(targetID)").font(TypeScale.time).foregroundStyle(.secondary)
                }
            }
        }
        .alert("Couldn't send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
        }
    }

    private func content(_ detail: BoardTargetDetailModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    breadcrumb(detail)
                    header(detail)
                    if !detail.isReadOnly {
                        fields(detail)
                        startProgress(detail)
                    }
                    if !detail.writes.isEmpty {
                        SectionHeader("Changes")
                        writeRows(detail.writes)
                    }
                    if !detail.intent.isEmpty {
                        Text(detail.intent).font(TypeScale.rowTitle).padding(.horizontal, Spacing.small)
                    }
                    code(detail)
                    waiting(detail)
                    subTargets(detail)
                    if !detail.sessions.isEmpty {
                        SectionHeader("Sessions on it", count: detail.sessions.count)
                        cardRows(detail.sessions) { row in
                            NavigationLink(value: SessionRoute(id: row.id)) { SessionRowView(row: row, insets: EdgeInsets()) }
                                .buttonStyle(.plain)
                        }
                    }
                    comments(detail)
                    if !detail.isReadOnly {
                        composer(detail).id(Self.composerID)
                    }
                }
                .padding(.horizontal, Spacing.large)
                .padding(.bottom, Spacing.large)
            }
            .background(Color(.systemBackground))
            .onChange(of: replyTo?.rootID) {
                if replyTo != nil { withAnimation(Motion.panel) { proxy.scrollTo(Self.composerID, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !detail.isReadOnly {
                PrimaryActionBar(primary: BarAction(title: "Work on it in a session") { startingSession = true })
            }
        }
        .sheet(isPresented: $addingSubTarget) {
            NewBoardTargetSheet(replica: replica, writer: writer, workbenchID: detail.target.workbenchID, parentID: detail.id)
        }
        .sheet(isPresented: $startingSession) {
            StartSessionSheet(workbenchID: detail.target.workbenchID, target: detail.target, fixed: true) { openSession = SessionRoute(id: $0) }
        }
        .navigationDestination(item: $openSession) { route in
            SessionDetailView(replica: replica, sessionID: route.id, store: env.store, requester: env.reportRequests)
        }
    }

    private static let composerID = "comment-composer"

    /// Rows of one kind on one card, a hairline between each two.
    private func cardRows<Item: Identifiable>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CardRowDivider() }
                row(item)
            }
        }
        .card(.plain, padding: EdgeInsets(top: Spacing.tight, leading: Spacing.medium, bottom: Spacing.tight, trailing: Spacing.medium))
    }

    private func writeRows(_ rows: [BoardWriteRow]) -> some View {
        cardRows(rows) { row in
            BoardWriteRowView(row: row, onApplyAnyway: applyAnyway, onDismiss: dismiss).padding(.vertical, Spacing.regular)
        }
    }

    /// Mockup 9's head: the status glyph, the title, then the card's chips
    /// and counter, and the progress bar.
    private func header(_ detail: BoardTargetDetailModel) -> some View {
        let card = detail.row.card
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Image(systemName: card.glyph)
                    .foregroundStyle(card.tone.color)
                    .frame(width: PhoneMetrics.iconColumn)
                Text(detail.title.isEmpty ? "Untitled" : detail.title)
                    .font(TypeScale.screenTitle)
                    .strikethrough(card.isDone)
            }
            FlowRow {
                Text(card.numberText).font(TypeScale.time).foregroundStyle(.secondary)
                ForEach(BoardCard.chipIDs(card), id: \.self) { Pill(item: card.chips[$0]) }
                if let counter = card.counter {
                    Text(counter).font(TypeScale.time).foregroundStyle(.secondary)
                }
            }
            if let progress = card.progress {
                ThinProgressBar(value: progress, tone: card.progressTone)
                    .padding(.top, Spacing.tight)
            }
        }
        .padding(.horizontal, Spacing.small)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func breadcrumb(_ detail: BoardTargetDetailModel) -> some View {
        if !detail.breadcrumb.isEmpty {
            HStack(spacing: Spacing.small) {
                ForEach(detail.breadcrumb) { crumb in
                    NavigationLink(value: BoardTargetRoute(id: crumb.id)) {
                        Text("\(crumb.title) ›").lineLimit(1)
                            .frame(minHeight: PhoneMetrics.minTouch)
                            .contentShape(Rectangle())
                    }
                }
            }
            .font(TypeScale.meta)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .padding(.horizontal, Spacing.small)
        }
    }

    /// The start's stage while a session is on its way.
    @ViewBuilder
    private func startProgress(_ detail: BoardTargetDetailModel) -> some View {
        if let progress = StartProgressModel.of(
            targetID: detail.id, attempt: env.sessionStarts.attempts[detail.id], snapshot: replica.snapshot, now: .now
        ) {
            Text(progress.caption)
                .font(TypeScale.meta)
                .foregroundStyle(progress.failure == nil ? Color.secondary : PhoneTone.red.color)
                .padding(.horizontal, Spacing.small)
                .accessibilityLabel("Session start: \(progress.caption)")
        }
    }

    /// Status and priority as menus, on one card; a group's "status follows
    /// its sub-tasks" is the note under it. The bindings are unchanged.
    private func fields(_ detail: BoardTargetDetailModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(title: "Status") {
                    Picker("Status", selection: Binding(get: { detail.status.selection }, set: { setStatus($0, detail) })) {
                        ForEach(detail.status.options, id: \.self) { Text(BoardRowModel.statusLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(!detail.status.isEnabled)
                    .accessibilityLabel("Status")
                    .accessibilityValue(BoardRowModel.statusLabel(detail.status.selection))
                }
                CardRowDivider()
                SettingsRow(title: "Priority") {
                    Picker("Priority", selection: Binding(get: { detail.priority.selection }, set: { setPriority($0, detail) })) {
                        ForEach(detail.priority.options, id: \.self) { Text(BoardRowModel.priorityName($0)).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(!detail.priority.isEnabled)
                    .accessibilityLabel("Priority")
                    .accessibilityValue(BoardRowModel.priorityName(detail.priority.selection))
                }
            }
            .card(.plain, padding: EdgeInsets(top: Spacing.tight, leading: Spacing.medium, bottom: Spacing.tight, trailing: Spacing.medium))
            if let caption = detail.status.caption {
                Text(caption).font(TypeScale.meta).foregroundStyle(.secondary).padding(.horizontal, Spacing.small)
            }
        }
    }

    @ViewBuilder
    private func code(_ detail: BoardTargetDetailModel) -> some View {
        if !detail.branch.isEmpty || !detail.pr.isEmpty {
            SectionHeader("Code")
            VStack(alignment: .leading, spacing: 0) {
                if !detail.branch.isEmpty {
                    SettingsRow(title: "Branch") { Text(detail.branch).font(TypeScale.code) }
                }
                if !detail.branch.isEmpty, !detail.pr.isEmpty { CardRowDivider() }
                if !detail.pr.isEmpty {
                    SettingsRow(title: "PR") { Text(detail.pr.allSatisfy(\.isNumber) ? "#\(detail.pr)" : detail.pr) }
                }
            }
            .card(.plain, padding: EdgeInsets(top: Spacing.tight, leading: Spacing.medium, bottom: Spacing.tight, trailing: Spacing.medium))
        }
    }

    @ViewBuilder
    private func waiting(_ detail: BoardTargetDetailModel) -> some View {
        if !detail.asks.isEmpty {
            SectionHeader("Waiting for you", count: detail.asks.count, tone: detail.asksHeaderTone)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(detail.asks.enumerated()), id: \.element.id) { index, card in
                    // A target's open asks: no permission request here.
                    if case let .ask(id) = card.destination {
                        if index > 0 { CardRowDivider(inset: Spacing.large) }
                        NavigationLink(value: AskRoute(id: id)) { AskRow(ask: card, showsChevron: true) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .card(.waiting, padding: EdgeInsets())
        }
    }

    @ViewBuilder
    private func subTargets(_ detail: BoardTargetDetailModel) -> some View {
        if !detail.children.isEmpty || !detail.isReadOnly {
            SectionHeader(detail.children.isEmpty ? "Sub-targets" : detail.childrenHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(detail.children) { child in
                    NavigationLink(value: BoardTargetRoute(id: child.id)) {
                        FlatRow(
                            icon: .symbol(child.statusGlyph, tone: child.statusTone), title: child.title, isDimmed: child.isDimmed,
                            insets: EdgeInsets(top: Spacing.regular, leading: 0, bottom: Spacing.regular, trailing: 0)
                        ) {
                            if child.hasMetaLine { MetaLine(items: child.details) }
                        }
                    }
                    .buttonStyle(.plain)
                    CardRowDivider()
                }
                if !detail.isReadOnly {
                    Button {
                        addingSubTarget = true
                    } label: {
                        Label("Add sub-target", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
            }
            .card(.plain, padding: EdgeInsets(top: Spacing.tight, leading: Spacing.medium, bottom: Spacing.tight, trailing: Spacing.medium))
        }
    }

    @ViewBuilder
    private func comments(_ detail: BoardTargetDetailModel) -> some View {
        if !detail.thread.isEmpty {
            SectionHeader("Comments", count: detail.comments.count)
            VStack(alignment: .leading, spacing: Spacing.medium) {
                ForEach(detail.thread) { item in
                    Group {
                        switch item {
                        case let .comment(comment): commentRow(comment)
                        case let .write(row, _): BoardWriteRowView(row: row, onApplyAnyway: applyAnyway, onDismiss: dismiss)
                        }
                    }
                    .padding(.leading, item.isReply ? Spacing.large : 0)
                }
            }
            .padding(.horizontal, Spacing.small)
        }
    }

    private func commentRow(_ comment: BoardTargetDetailModel.CommentRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack {
                Text(comment.author).font(TypeScale.kind)
                Text(comment.age).font(TypeScale.meta).foregroundStyle(.secondary)
                if comment.isResolved {
                    Text("Resolved").font(TypeScale.meta).foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.small)
                if comment.canReply {
                    Button {
                        replyTo = comment
                        composerFocused = true
                    } label: {
                        Text("Reply")
                            .frame(minHeight: PhoneMetrics.minTouch)
                            .contentShape(Rectangle())
                    }
                    .font(TypeScale.meta)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Reply to \(comment.author)")
                }
            }
            Text(comment.body).font(.subheadline)
        }
    }

    /// The comment composer, the last block of the page.
    private func composer(_ detail: BoardTargetDetailModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let replyTo {
                HStack {
                    Text("Replying to \(replyTo.author)").font(TypeScale.meta).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { self.replyTo = nil }
                        .font(TypeScale.meta)
                        .frame(minHeight: PhoneMetrics.minTouch)
                        .accessibilityLabel("Cancel the reply")
                }
            }
            HStack(alignment: .bottom, spacing: Spacing.regular) {
                TextField(replyTo == nil ? "Add a comment" : "Reply", text: $draft.text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(Spacing.regular)
                    .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                            .strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline)
                    )
                    .accessibilityLabel(replyTo == nil ? "Comment" : "Reply")
                Button {
                    send(detail)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .frame(minWidth: PhoneMetrics.minTouch, minHeight: PhoneMetrics.minTouch)
                .disabled(!draft.canSend || detail.composerSending(replyRoot: replyTo?.rootID))
                .accessibilityLabel(replyTo == nil ? "Send comment" : "Send reply")
            }
        }
    }

    // MARK: - Actions

    private func setStatus(_ status: WorkbenchTargetStatus, _ detail: BoardTargetDetailModel) {
        run { try await writer.setStatus(status, on: detail.target) }
    }

    private func setPriority(_ priority: WorkbenchTargetPriority, _ detail: BoardTargetDetailModel) {
        run { try await writer.setPriority(priority, on: detail.target) }
    }

    private func send(_ detail: BoardTargetDetailModel) {
        let text = draft.text
        let root = replyTo
        run {
            let sent: Bool
            if let root {
                sent = try await writer.reply(text, toRoot: root.rootID, workbenchID: detail.target.workbenchID)
            } else {
                sent = try await writer.addComment(text, on: detail.target)
            }
            // A draft edited while it was sending is kept.
            if sent, draft.text == text {
                draft.text = ""
                replyTo = nil
            }
        }
    }

    private func applyAnyway(_ row: BoardWriteRow) {
        run { try await writer.applyAnyway(row) }
    }

    private func dismiss(_ row: BoardWriteRow) {
        run { try writer.dismiss(row) }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                sendError = BoardWriteText.sendError(error)
            }
        }
    }
}
