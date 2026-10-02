import SwiftUI
import WatchtowerCore

/// The selected board target as a card over the board (board #155/#156): a
/// header (editable title, close), a metadata row of capsule menus, Work on
/// it with the progress, then the intent, documents, images and comment
/// threads; the comment composer stays pinned under them. The card is as
/// tall as its content and scrolls inside once the pane is shorter.
struct WorkbenchTargetDetailCard: View {
    let vm: WorkbenchBoardViewModel
    let node: WorkbenchBoardNode
    /// The board drift findings on this target (PROJ-07), shown as chips.
    let findings: [WorkbenchDriftFinding]
    /// Owned by the board view so a half-typed title or comment survives
    /// the card closing and reopening.
    @Binding var titleDraft: String
    @Binding var commentDraft: String
    let onClose: () -> Void

    /// The scrolling body's natural height; the scroll view never asks for
    /// more, so a short target gets a short card.
    @State private var contentHeight: CGFloat = .infinity

    private var target: Target { node.target }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(maxHeight: contentHeight)
            Divider()
            // The board's banner sits under the scrim while the card is open,
            // so a failed rename, status, priority or comment write shows here.
            if let error = vm.errorMessage {
                errorRow(error)
            }
            composer
        }
        .onAppear { titleDraft = target.text }
        .onChange(of: target.id) { titleDraft = target.text }
        .onChange(of: target.text) { titleDraft = target.text }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                // A wrapping field: a long title shows whole instead of being
                // cut at the card's edge. Return renames.
                TextField("Title", text: $titleDraft, axis: .vertical)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit { vm.rename(titleDraft) }
                    .help("Edit the title; Return saves it")
                closeButton
            }
            FlowLayout(spacing: 6) {
                numberButton
                statusMenu
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
            HStack(spacing: 12) {
                WorkOnTargetButton(target: target, compact: false, isVisible: true)
                    .fixedSize()
                Spacer(minLength: 0)
                progress
            }
        }
        .padding(16)
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

    /// Read-only, as before: the agent's tools set a target's progress.
    private var progress: some View {
        let value = min(max(target.progress, 0), 1)
        return HStack(spacing: 6) {
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(value >= 1 ? .green : .accentColor)
                .frame(minWidth: 50, maxWidth: 140)
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Progress")
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
            if !target.intent.isEmpty {
                Text(target.intent)
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !node.documents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    WorkbenchDetailSectionHeader(title: "Documents", systemImage: "doc.text", count: node.documents.count)
                    ForEach(node.documents, id: \.id) { doc in
                        Label(doc.title.isEmpty ? doc.relPath : doc.title, systemImage: "doc.text")
                            .font(.callout)
                            .lineLimit(2)
                            .help(doc.relPath)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if !vm.selectedImages.isEmpty {
                WorkbenchTargetImagesSection(images: vm.selectedImages)
            }
            VStack(alignment: .leading, spacing: 8) {
                WorkbenchDetailSectionHeader(title: "Comments", systemImage: "bubble.left.and.bubble.right", count: vm.threads.count)
                if vm.threads.isEmpty {
                    Text("No comments yet. Agents ask their questions here; write below to ask or answer.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(vm.threads) { thread in
                    CommentThreadView(
                        thread: thread.content,
                        onReply: { vm.reply(to: thread.id, body: $0) },
                        onResolve: thread.root.isOpen ? { vm.setThreadStatus(rootID: thread.id, status: "resolved") } : nil,
                        onReopen: thread.root.isOpen ? nil : { vm.setThreadStatus(rootID: thread.id, status: "open") }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: - Composer

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { vm.dismissError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    private var canSend: Bool {
        !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        // Cleared only once the comment is saved: a failed write keeps the text.
        if vm.addComment(commentDraft) { commentDraft = "" }
    }

    /// The chat composer's idiom: a rounded field and a round send button.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Return is a new line; ⌘↩ or ⌃↩ sends, and only while this
            // field has focus: a window-wide shortcut would also fire from a
            // terminal in the other split pane and post a stale draft.
            CommentTextEditor(text: $commentDraft, placeholder: "Comment or answer the agent…",
                              minHeight: 34, maxHeight: 140, cornerRadius: 16, onSubmit: send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(canSend ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.borderless)
            .disabled(!canSend)
            .help("Comment (⌘↩ or ⌃↩)")
            .accessibilityLabel("Comment")
            .padding(.bottom, 3)
        }
        .padding(12)
    }
}

/// A section title inside the target detail card (Documents, Images,
/// Comments), so every section reads the same.
struct WorkbenchDetailSectionHeader: View {
    let title: String
    let systemImage: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A status or priority menu's label: a tinted capsule with an icon and a
/// chevron, so it reads as a control rather than a bare tag.
private struct WorkbenchDetailMenuLabel: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(color)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.5))
    }
}
