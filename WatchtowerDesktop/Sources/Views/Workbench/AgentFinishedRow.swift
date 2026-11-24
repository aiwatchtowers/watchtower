import AppKit
import ChatUI
import SwiftUI
import WatchtowerChatText
import WatchtowerCore

/// A task notification in the Workchat (spec 2026-11-24-workchat-polish §3, D4): one quiet row — the status glyph
/// tinted by `Tone`, the agent's name (`#N` in `SyntaxTint.ref`, C8) and the meta line; expanded, under a thin rule,
/// the result and the text buttons Open output and Details. A background command is the same row, caption-sized, its
/// meta on the title's line. No fill, no pill, no bold.
struct AgentFinishedRow: View {
    let presentation: AgentFinishedPresentation
    /// The task's output file; "" hides Open output.
    let outputFile: String
    let expanded: Bool
    var onToggle: (() -> Void)?
    var onOpenOutput: ((String) -> Void)?
    /// The ids line under the buttons (Details toggles it).
    @State private var showsDetails: Bool

    init(
        presentation: AgentFinishedPresentation,
        outputFile: String,
        expanded: Bool,
        onToggle: (() -> Void)? = nil,
        onOpenOutput: ((String) -> Void)? = nil,
        showsDetails: Bool = false
    ) {
        self.presentation = presentation
        self.outputFile = outputFile
        self.expanded = expanded
        self.onToggle = onToggle
        self.onOpenOutput = onOpenOutput
        _showsDetails = State(initialValue: showsDetails)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                onToggle?()
            } label: {
                header.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { expandedBody }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: presentation.glyph)
                .font((presentation.isCommand ? Font.caption2 : .caption).weight(.semibold))
                .foregroundStyle(Self.tint(presentation.tone).opacity(SyntaxTint.opacity))
                .frame(width: IconSize.header)
            if presentation.isCommand {
                Text(Self.title(presentation.title)).foregroundStyle(.secondary).lineLimit(1)
                Text(presentation.meta).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(Self.title(presentation.title)).foregroundStyle(.secondary).lineLimit(2)
                    Text(presentation.meta).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: Spacing.regular)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: IconSize.chevron, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .font(presentation.isCommand ? .caption : .callout)
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.small)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let result = presentation.result {
                Text(AgentFinishedPresentation.resultLabel)
                    .font(.caption2)
                    .tracking(Tracking.caps)
                    .foregroundStyle(.tertiary)
                Text(Self.inlineMarkdown(result)).font(.callout).textSelection(.enabled)
            }
            HStack(spacing: Spacing.medium) {
                if !outputFile.isEmpty, let onOpenOutput {
                    Button(AgentFinishedPresentation.openOutputTitle) { onOpenOutput(outputFile) }
                        .buttonStyle(KitQuietButtonStyle(label: .secondary))
                }
                if !presentation.details.isEmpty {
                    Button(AgentFinishedPresentation.detailsTitle) { showsDetails.toggle() }
                        .buttonStyle(KitQuietButtonStyle(label: Color(nsColor: .tertiaryLabelColor)))
                }
            }
            .font(.caption)
            .padding(.top, presentation.result == nil ? 0 : Spacing.small)
            if showsDetails {
                Text(presentation.details)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, Spacing.medium)
        .padding(.vertical, Spacing.tight)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: Stroke.hairline * 2)
        }
        // The rule sits under the status glyph.
        .padding(.leading, Spacing.regular + IconSize.header / 2)
        .padding(.bottom, Spacing.small)
    }

    static func tint(_ tone: AgentFinishedPresentation.Tone) -> Color {
        switch tone {
        case .success: Tone.success
        case .failure: Tone.error
        case .neutral: .secondary
        }
    }

    /// The title with its `#N` refs in `SyntaxTint.ref` (C8); colour only, the row's click expands it.
    static func title(_ title: String) -> AttributedString {
        var text = AttributedString(title)
        for span in AgentTextHighlights.spans(inPlain: title) {
            guard case .ref = span.kind, let range = Range(span.range, in: text) else { continue }
            text[range].foregroundColor = SyntaxTint.ref
        }
        return text
    }

    /// The result's inline Markdown (`code`, emphasis); the plain text when it does not parse.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // MARK: - Open output

    /// The most of an output file the viewer shows; the rest is cut (an agent's output is its whole transcript).
    nonisolated static let outputLimit = 256 * 1024

    /// Open output: a file under the session's Claude Code temp dir opens read-only in the chat's code viewer, any
    /// other is revealed in Finder; a file that is gone beeps.
    static func openOutput(_ path: String, claudeSessionID: String?, openArtifact: @escaping (ChatArtifactContent) -> Void) {
        let url = URL(fileURLWithPath: path)
        guard AgentFinishedPresentation.outputOpensInViewer(path, claudeSessionID: claudeSessionID) else {
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSSound.beep()
            }
            return
        }
        Task {
            let read = await Task.detached(priority: .userInitiated) { readOutput(url) }.value
            guard let read else { NSSound.beep(); return }
            openArtifact(ChatArtifactContent(key: "task-output:\(path)", kind: "code", title: url.lastPathComponent,
                                             content: read.text, contentCut: read.cut))
        }
    }

    /// The file's first `outputLimit` bytes as text, and whether there was more; nil when it cannot be read.
    nonisolated static func readOutput(_ url: URL) -> (text: String, cut: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: outputLimit + 1) ?? Data()
        } catch {
            return nil
        }
        let cut = data.count > outputLimit
        // Lossy on purpose: the cut can split a character.
        // swiftlint:disable:next optional_data_string_conversion
        return (String(decoding: data.prefix(outputLimit), as: UTF8.self), cut)
    }
}
