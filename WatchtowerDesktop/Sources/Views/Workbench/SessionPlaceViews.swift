import AppKit
import SwiftUI
import WatchtowerCore

/// A session row's place line (board #565): `⑂ mobile-a · feature/x`,
/// `main folder · main`, `worktree removed`.
struct SessionPlaceLine: View {
    let label: SessionPlacePresentation.PlaceLabel
    var font: Font = .caption2

    var body: some View {
        // The text carries the worktree glyph itself.
        Text(label.text)
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(label.help)
    }
}

/// A bench folder's name with the folder glyph, in the accent colour (spec
/// 2026-11-18 §6.2): before a session row's place on a bench of several
/// folders, and as a crumb on its strip.
struct SessionFolderLabel: View {
    let name: String
    var font: Font = .caption2

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "folder")
            Text(name).lineLimit(1)
        }
        .font(font)
        .foregroundStyle(Color.accentColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Folder \(name)")
    }
}

/// The header's worktree crumb (`📁 ~/folder › ⑂ mobile-a · feature/x ›
/// ⎇ branch`): the session on screen works in a linked worktree (a click
/// reveals its folder in Finder) or in one since removed. Nothing for the
/// main folder.
struct WorkbenchPlaceCrumb: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench

    var body: some View {
        if let place = vm.headerPlace(projectID: project.id) {
            HStack(spacing: 4) {
                Text("›")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                if let folder = place.folder {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } label: {
                        SessionPlaceLine(label: place.label, font: .caption)
                    }
                    .buttonStyle(.link)
                    .help("\(place.label.help)\nShow in Finder")
                } else {
                    SessionPlaceLine(label: place.label, font: .caption)
                }
            }
            .layoutPriority(-1)
        }
    }
}
