import AppKit
import SwiftUI
import WatchtowerCore

/// The bar over an html/htm file in the Files pane (#535): Source | Preview,
/// and Reload, Present and Open in Browser. The preview shows the file as it
/// is on disk (edits save themselves within a second) in the sandboxed web
/// view; its relative css/js/images load from the file's own folder only.
struct CodeHTMLPreviewBar: View {
    let buffer: CodeFileBuffer
    /// The code root the file is in (the workbench folder or its session
    /// worktree): the browser serves no hidden folder below it.
    let root: URL
    @Binding var isOn: Bool
    @Binding var reload: Int
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            row
            CodeHTMLBlockedBanner(html: buffer.diskText)
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Picker("View", selection: $isOn) {
                Text("Source").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if isOn {
                Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Load the page again")
                    .accessibilityLabel("Reload")
            }
            Button {
                HTMLPreviewWindow.show(CodeHTMLPreview.content(buffer.url), title: buffer.url.lastPathComponent, fullScreen: true)
            } label: { Image(systemName: "play.rectangle") }
                .buttonStyle(.borderless)
                .help("Present full screen; the arrow keys page through a deck, Esc leaves")
                .accessibilityLabel("Present")
            Button {
                let folder = buffer.url.deletingLastPathComponent()
                let name = buffer.url.lastPathComponent
                Task { notice = await HTMLBrowserOpener.open(file: name, inFolder: folder, within: root) }
            } label: { Image(systemName: "safari") }
                .buttonStyle(.borderless)
                .help("Open in your browser from a private local address that serves only this file's folder")
                .accessibilityLabel("Open in Browser")
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

/// "Blocked N external resources: host1, host2…" under the bar (#563): what
/// the file's markup names outside the CDN allowlist, which neither the
/// preview nor the browser loads. Nothing when everything is local or on
/// the allowlist.
private struct CodeHTMLBlockedBanner: View {
    let html: String

    var body: some View {
        if let banner = HTMLPreviewPolicy.blockedResources(in: html).banner() {
            Label(banner, systemImage: "shield.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("\(banner). Only \(HTMLPreviewPolicy.cdnHosts.joined(separator: ", ")) are allowed.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
        }
    }
}

/// The preview itself, over the editor while Preview is on. It loads again
/// whenever the file's text on disk changes (an autosave, or another
/// program — an agent — writing it) and on Reload.
struct CodeHTMLPreviewPane: View {
    let buffer: CodeFileBuffer
    let reload: Int
    @State private var diskChanges = 0

    var body: some View {
        SandboxedHTMLView(content: CodeHTMLPreview.content(buffer.url), reloadToken: diskChanges &+ reload, focusOnLoad: true)
            .onChange(of: buffer.diskText) { diskChanges &+= 1 }
    }
}

enum CodeHTMLPreview {
    /// Standardized, so the page's own URL starts with the folder URL the
    /// content rules allow (`HTMLPreviewPolicy.visibleFilesFilter`).
    static func content(_ file: URL) -> SandboxedHTMLContent {
        let file = file.standardizedFileURL
        return .file(file, folder: file.deletingLastPathComponent())
    }
}

/// "Open in Browser" for a workbench file: its folder through the app's
/// loopback server (`LocalPreviewServer`: 127.0.0.1 only, an unguessable
/// token per folder, GET/HEAD, a sandboxing CSP). Workbench files only —
/// a chat artifact is never handed to a networked app (CHAT-05).
@MainActor
enum HTMLBrowserOpener {
    /// Nil on success, else a sentence for the caller to show.
    static func open(file: String, inFolder folder: URL, within root: URL) async -> String? {
        do {
            let url = try await LocalPreviewServer.shared.url(
                forFile: file, inFolder: folder, within: root, id: "folder:\(folder.path)"
            )
            return NSWorkspace.shared.open(url) ? nil : "Could not open the browser."
        } catch {
            return error.localizedDescription
        }
    }
}
