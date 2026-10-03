import AppKit
import SwiftUI
import WatchtowerCore

/// The jump bar above the editor (spec §8.4), in place of the old path
/// line: ‹ › (the back/forward history), then folders › file › type ›
/// method at the cursor, each segment a menu of its neighbours; the file
/// keeps its git mark and Saved/Edited state. At the end, muted: a
/// go-to-definition miss for 2 s, else a failed index's message, or
/// "Language X: text search" for a language the index does not read.
///
/// It is the only view reading the editor's cursor (up to 10 a second),
/// so those updates re-render the bar and nothing else of the pane.
struct JumpBar: View {
    let files: CodeFilesCenter
    let project: Workbench
    let buffer: CodeFileBuffer
    let status: GitFileStatus?
    @State private var controller: JumpBarController

    init(files: CodeFilesCenter, project: Workbench, buffer: CodeFileBuffer, status: GitFileStatus?) {
        self.files = files
        self.project = project
        self.buffer = buffer
        self.status = status
        _controller = State(initialValue: JumpBarController(files: files, project: project))
    }

    var body: some View {
        let snapshot = controller.snapshot()
        HStack(spacing: 4) {
            historyButtons
            if let model = snapshot?.model {
                segments(model)
            }
            Spacer(minLength: 8)
            trailingNote(snapshot?.model.status)
            Button {
                NSWorkspace.shared.open(buffer.url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Open in the default app")
            .accessibilityLabel("Open in the default app")
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 6)
        .frame(height: 24)
        .onAppear { files.navigation?.registerJumpBar(controller, for: project.id) }
        .onDisappear { files.navigation?.unregisterJumpBar(controller, for: project.id) }
    }

    @ViewBuilder
    private var historyButtons: some View {
        let navigation = files.navigation
        Button {
            navigation?.goBack(project: project)
        } label: {
            Image(systemName: "chevron.left")
        }
        .disabled(navigation?.canGoBack(workbenchID: project.id) != true)
        .help("Back (⌃⌘←)")
        .accessibilityLabel("Back")
        Button {
            navigation?.goForward(project: project)
        } label: {
            Image(systemName: "chevron.right")
        }
        .disabled(navigation?.canGoForward(workbenchID: project.id) != true)
        .help("Forward (⌃⌘→)")
        .accessibilityLabel("Forward")
    }

    private func segments(_ model: JumpBarModel) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(model.segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                JumpBarSegmentButton(
                    action: { controller.showMenu(segment: index) },
                    anchor: { controller.setAnchor($0, segment: index) },
                    label: { segmentLabel(segment) }
                )
                .layoutPriority(isFolder(segment) ? 0 : 1)
            }
        }
    }

    @ViewBuilder
    private func segmentLabel(_ segment: JumpBarSegment) -> some View {
        switch segment {
        case let .folder(name, _):
            Label(name, systemImage: "folder")
                .labelStyle(JumpBarLabelStyle())
                .accessibilityLabel("Folder \(name)")
        case let .file(path):
            HStack(spacing: 4) {
                Label(CodeFilesPaneView.name(path), systemImage: "doc.text")
                    .labelStyle(JumpBarLabelStyle())
                    .foregroundStyle(status.map(GitMark.color) ?? .primary)
                if let status {
                    Text(status.letter)
                        .monospaced()
                        .foregroundStyle(GitMark.color(status))
                        .help("Not committed")
                }
                Text(saveState.text)
                    .foregroundStyle(.secondary)
            }
            .help(buffer.url.path)
        case let .symbol(symbol):
            HStack(spacing: 3) {
                CodeKindBadge(kind: symbol.kind, size: 15)
                Text(symbol.name).lineLimit(1).truncationMode(.middle)
            }
            .help(symbol.signature.isEmpty ? symbol.name : symbol.signature)
        }
    }

    private var saveState: JumpBarSaveState {
        JumpBarSaveState(hasError: buffer.problem != nil || buffer.saveError != nil, deletedOnDisk: buffer.deletedOnDisk, isDirty: buffer.isDirty)
    }

    /// The 2 s go-to-definition notice wins over the status.
    @ViewBuilder
    private func trailingNote(_ status: JumpBarStatus?) -> some View {
        if let notice = files.navigation?.notice(for: project.id) {
            Label(notice, systemImage: "questionmark.circle")
                .lineLimit(1)
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        } else if let status {
            Text(status.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .help(status.text)
        }
    }

    private func isFolder(_ segment: JumpBarSegment) -> Bool {
        if case .folder = segment { return true }
        return false
    }
}

/// A segment: a borderless button with a hover background, and a plain
/// `NSView` behind it that the segment's menu drops from.
private struct JumpBarSegmentButton<Label: View>: View {
    let action: () -> Void
    let anchor: (NSView) -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(isHovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .background(JumpBarAnchorView(register: anchor))
        .onHover { isHovering = $0 }
        .accessibilityHint("Shows a menu of its neighbours")
    }
}

/// Icon and title tight together, the title truncating in the middle.
private struct JumpBarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(.secondary)
            configuration.title.lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Hands its `NSView` to the controller, for `NSMenu.popUp(…in:)`.
private struct JumpBarAnchorView: NSViewRepresentable {
    let register: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(view)
        return view
    }

    /// The segment at this place may have changed: register again.
    func updateNSView(_ view: NSView, context: Context) {
        register(view)
    }
}
