import SwiftUI
import WatchtowerDesign

/// What the composer's attachments are doing while they await the engine (board #670): files being stored, removals
/// under way, a send waiting for them, and the phone's uploads in flight or refused.
public struct AttachmentProgress: Equatable {
    /// Files being stored, by name (shown as chips of their own, with progress).
    public var importing: [String]
    public var removing: Set<Int64>
    public var sendWaits: Bool
    /// The phone's refused uploads: their chip offers Retry.
    public var failed: Set<Int64>
    /// The phone's uploads in flight: their chip shows progress and cannot be removed.
    public var uploading: Set<Int64>

    public init(
        importing: [String] = [],
        removing: Set<Int64> = [],
        sendWaits: Bool = false,
        failed: Set<Int64> = [],
        uploading: Set<Int64> = []
    ) {
        self.importing = importing
        self.removing = removing
        self.sendWaits = sendWaits
        self.failed = failed
        self.uploading = uploading
    }

    public var isEmpty: Bool { importing.isEmpty }
}

/// One attachment chip as `ChatUIStyle.attachmentChip` draws it.
public struct ChatAttachmentChipContent {
    public enum State: Equatable, Sendable {
        /// Attached; removable unless a removal runs.
        case attached
        /// Being stored (the Mac's import) or uploaded (the phone's): progress, no remove.
        case importing
        /// The phone's refused upload: Retry.
        case failed
    }

    public let name: String
    public let icon: String
    public let state: State
    public let removeDisabled: Bool
    /// nil: a read-only chip.
    public let onRemove: (() -> Void)?
    public let onRetry: (() -> Void)?

    public init(
        name: String,
        icon: String,
        state: State,
        removeDisabled: Bool = false,
        onRemove: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.name = name
        self.icon = icon
        self.state = state
        self.removeDisabled = removeDisabled
        self.onRemove = onRemove
        self.onRetry = onRetry
    }
}

/// The draft's attachment chips, then the files still being stored. `onRemove == nil` draws read-only chips.
public struct AttachmentChipsView: View {
    let attachments: [ChatComposerAttachment]
    var onRemove: ((Int64) -> Void)?
    var onRetry: ((Int64) -> Void)?
    var progress: AttachmentProgress
    @Environment(\.chatUIStyle) private var style

    public init(
        attachments: [ChatComposerAttachment],
        onRemove: ((Int64) -> Void)? = nil,
        onRetry: ((Int64) -> Void)? = nil,
        progress: AttachmentProgress = AttachmentProgress()
    ) {
        self.attachments = attachments
        self.onRemove = onRemove
        self.onRetry = onRetry
        self.progress = progress
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ComposerMetrics.attachmentChipSpacing) {
                ForEach(chips.indices, id: \.self) { index in
                    style.attachmentChip(chips[index])
                }
            }
        }
    }

    /// The chips in order: the attached files, then the files being stored.
    public var chips: [ChatAttachmentChipContent] {
        attachments.map { attachment in
            let id = attachment.id
            let state: ChatAttachmentChipContent.State = progress.failed.contains(id) ? .failed
                : progress.uploading.contains(id) ? .importing : .attached
            return ChatAttachmentChipContent(
                name: attachment.name,
                icon: ComposerAttachmentRules.icon(forMime: attachment.mime),
                state: state,
                removeDisabled: progress.removing.contains(id) || progress.uploading.contains(id),
                onRemove: onRemove.map { remove in { remove(id) } },
                onRetry: state == .failed ? onRetry.map { retry in { retry(id) } } : nil
            )
        } + progress.importing.map { ChatAttachmentChipContent(name: $0, icon: "", state: .importing) }
    }
}
