import AppKit
import SwiftUI
import WatchtowerCore

/// The selected board target's images (board target #117): thumbnails in the
/// detail pane, a click opens the full image in a sheet. Read-only — only the
/// agent's project tools attach or detach images.
struct ProjectTargetImagesSection: View {
    let images: [ProjectTargetImage]
    @State private var shown: ProjectTargetImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Images").font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(images) { image in
                    Button { shown = image } label: { ProjectImageThumbnail(image: image) }
                        .buttonStyle(.plain)
                        .help(image.fileName)
                }
            }
        }
        .sheet(item: $shown) { ProjectImageViewer(image: $0) }
    }
}

/// One thumbnail, decoded off the main actor.
private struct ProjectImageThumbnail: View {
    let image: ProjectTargetImage
    @State private var load: ProjectImageLoad?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            switch load {
            case .image(let thumbnail):
                Image(decorative: thumbnail, scale: 2)
                    .resizable()
                    .scaledToFill()
            case .missing:
                Label("Missing", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .undecodable:
                Label("Can't show", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 112, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .task(id: image.path) {
            let url = image.fileURL
            load = await Task.detached(priority: .utility) {
                ProjectImageLoader.load(at: url, maxPixel: 448)
            }.value
        }
    }
}

/// The full-size image, scrollable when larger than the sheet.
private struct ProjectImageViewer: View {
    let image: ProjectTargetImage
    @Environment(\.dismiss) private var dismiss
    @State private var load: ProjectImageLoad?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(image.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([image.fileURL])
                }
                .disabled(load == nil || isMissing)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            Group {
                switch load {
                case .image(let full):
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: full, scale: 1)
                    }
                case .missing:
                    ContentUnavailableView(
                        "Image not found",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("Watchtower's copy of this image is missing.")
                    )
                case .undecodable:
                    ContentUnavailableView(
                        "Can't show this image",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The file is there but could not be decoded. Show in Finder opens it.")
                    )
                case nil:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, idealWidth: 900, minHeight: 360, idealHeight: 680)
        .task(id: image.path) {
            let url = image.fileURL
            load = await Task.detached(priority: .userInitiated) {
                ProjectImageLoader.load(at: url, maxPixel: ProjectImageLoader.viewerMaxPixel)
            }.value
        }
    }

    private var isMissing: Bool {
        if case .missing = load { return true }
        return false
    }
}
