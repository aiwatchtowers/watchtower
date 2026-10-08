import SwiftUI
import WatchtowerKit

/// A board target: breadcrumb, title, status and priority pickers, intent,
/// branch and PR, sub-targets (with Add sub-target), sessions on it, open
/// asks, the comment threads with Reply, and the composer. The phone's
/// writes show in place until the Mac applies them. An archived target is
/// read-only.
struct BoardTargetDetailView: View {
    let replica: WorkbenchReplicaModel
    let writer: BoardWriter
    let targetID: Int64
    @State private var draft = CommentDraft()
    /// The root a reply goes under; nil for a new comment.
    @State private var replyTo: BoardTargetDetailModel.CommentRow?
    @State private var addingSubTarget = false
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
        .alert("Couldn't send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
        }
    }

    private func content(_ detail: BoardTargetDetailModel) -> some View {
        List {
            header(detail)
            if !detail.writes.isEmpty {
                Section("Changes") {
                    ForEach(detail.writes) { row in
                        BoardWriteRowView(row: row, onApplyAnyway: applyAnyway, onDismiss: dismiss)
                    }
                }
            }
            if !detail.intent.isEmpty {
                Section("Intent") { Text(detail.intent) }
            }
            if !detail.branch.isEmpty || !detail.pr.isEmpty {
                Section("Code") {
                    if !detail.branch.isEmpty {
                        LabeledContent("Branch") { Text(detail.branch).font(.callout.monospaced()) }
                    }
                    if !detail.pr.isEmpty {
                        LabeledContent("PR", value: detail.pr.allSatisfy(\.isNumber) ? "#\(detail.pr)" : detail.pr)
                    }
                }
            }
            if !detail.asks.isEmpty {
                Section("Waiting for you") {
                    ForEach(detail.asks) { card in
                        NavigationLink(value: AskRoute(id: card.id)) { WaitingCardView(card: card) }
                            .listRowSeparator(.hidden)
                    }
                }
            }
            if !detail.children.isEmpty || !detail.isReadOnly {
                Section(detail.children.isEmpty ? "Sub-targets" : detail.childrenHeader) {
                    ForEach(detail.children) { child in
                        NavigationLink(value: BoardTargetRoute(id: child.id)) { BoardRowView(row: child) }
                    }
                    if !detail.isReadOnly {
                        Button {
                            addingSubTarget = true
                        } label: {
                            Label("Add sub-target", systemImage: "plus")
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            if !detail.sessions.isEmpty {
                Section("Sessions on it") {
                    ForEach(detail.sessions) { row in
                        NavigationLink(value: SessionRoute(id: row.id)) { SessionRowView(row: row) }
                    }
                }
            }
            comments(detail)
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if !detail.isReadOnly { composer(detail) }
        }
        .sheet(isPresented: $addingSubTarget) {
            NewBoardTargetSheet(replica: replica, writer: writer, workbenchID: detail.target.workbenchID, parentID: detail.id)
        }
    }

    @ViewBuilder
    private func header(_ detail: BoardTargetDetailModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if !detail.breadcrumb.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(detail.breadcrumb) { crumb in
                            NavigationLink(value: BoardTargetRoute(id: crumb.id)) {
                                Text("\(crumb.title) ›").lineLimit(1)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
                }
                Text(detail.title).font(.headline)
                if detail.isReadOnly {
                    readOnlyLine(detail)
                } else {
                    pickers(detail)
                }
            }
        }
    }

    private func readOnlyLine(_ detail: BoardTargetDetailModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: detail.row.statusGlyph).foregroundStyle(detail.row.statusTone.color)
            Text(detail.statusLabel)
            if let priority = detail.row.priorityLabel {
                Text(priority)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(detail.row.priorityTone.color)
            }
            if let progress = detail.row.progressText {
                Text(progress).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private func pickers(_ detail: BoardTargetDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker(selection: Binding(get: { detail.status.selection }, set: { setStatus($0, detail) })) {
                    ForEach(detail.status.options, id: \.self) { Text(BoardRowModel.statusLabel($0)).tag($0) }
                } label: {
                    Text("Status")
                }
                .pickerStyle(.menu)
                .disabled(!detail.status.isEnabled)
                .frame(minHeight: 44)
                .accessibilityLabel("Status")
                .accessibilityValue(BoardRowModel.statusLabel(detail.status.selection))
                Picker(selection: Binding(get: { detail.priority.selection }, set: { setPriority($0, detail) })) {
                    ForEach(detail.priority.options, id: \.self) { Text(BoardRowModel.priorityName($0)).tag($0) }
                } label: {
                    Text("Priority")
                }
                .pickerStyle(.menu)
                .disabled(!detail.priority.isEnabled)
                .frame(minHeight: 44)
                .accessibilityLabel("Priority")
                .accessibilityValue(BoardRowModel.priorityName(detail.priority.selection))
                if let progress = detail.row.progressText {
                    Text(progress).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let caption = detail.status.caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func comments(_ detail: BoardTargetDetailModel) -> some View {
        if !detail.thread.isEmpty {
            Section("Comments · \(detail.comments.count)") {
                ForEach(detail.thread) { item in
                    Group {
                        switch item {
                        case let .comment(comment): commentRow(comment)
                        case let .write(row, _): BoardWriteRowView(row: row, onApplyAnyway: applyAnyway, onDismiss: dismiss)
                        }
                    }
                    .padding(.leading, item.isReply ? 16 : 0)
                }
            }
        }
    }

    private func commentRow(_ comment: BoardTargetDetailModel.CommentRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(comment.author).font(.caption.weight(.semibold))
                Text(comment.age).font(.caption).foregroundStyle(.secondary)
                if comment.isResolved {
                    Text("Resolved").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if comment.canReply {
                    Button("Reply") {
                        replyTo = comment
                        composerFocused = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Reply to \(comment.author)")
                }
            }
            Text(comment.body).font(.subheadline)
        }
    }

    private func composer(_ detail: BoardTargetDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let replyTo {
                HStack {
                    Text("Replying to \(replyTo.author)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { self.replyTo = nil }
                        .font(.caption)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Cancel the reply")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(replyTo == nil ? "Add a comment" : "Reply", text: $draft.text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($composerFocused)
                    .accessibilityLabel(replyTo == nil ? "Comment" : "Reply")
                Button {
                    send(detail)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!draft.canSend || detail.composerSending(replyRoot: replyTo?.rootID))
                .accessibilityLabel(replyTo == nil ? "Send comment" : "Send reply")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
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
