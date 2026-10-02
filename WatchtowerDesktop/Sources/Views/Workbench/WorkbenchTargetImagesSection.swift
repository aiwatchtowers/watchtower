import AppKit
import SwiftUI
import WatchtowerCore

/// The selected board target's images (board target #117): thumbnails in the
/// detail pane, a click opens the full image in a sheet. Read-only — only the
/// agent's project tools attach or detach images.
struct WorkbenchTargetImagesSection: View {
    let images: [WorkbenchTargetImage]
    @State private var shown: WorkbenchTargetImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkbenchDetailSectionHeader(title: "Images", systemImage: "photo", count: images.count)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(images) { image in
                    Button { shown = image } label: { WorkbenchImageThumbnail(image: image) }
                        .buttonStyle(.plain)
                        .help(image.fileName)
                }
            }
        }
        .sheet(item: $shown) { WorkbenchImageViewer(image: $0) }
    }
}

/// One thumbnail, decoded off the main actor.
private struct WorkbenchImageThumbnail: View {
    let image: WorkbenchTargetImage
    @State private var load: WorkbenchImageLoad?

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
                WorkbenchImageLoader.load(at: url, maxPixel: 448)
            }.value
        }
    }
}

/// The full-size image, scrollable when larger than the sheet.
private struct WorkbenchImageViewer: View {
    let image: WorkbenchTargetImage
    @Environment(\.dismiss) private var dismiss
    @State private var load: WorkbenchImageLoad?

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
                WorkbenchImageLoader.load(at: url, maxPixel: WorkbenchImageLoader.viewerMaxPixel)
            }.value
        }
    }

    private var isMissing: Bool {
        if case .missing = load { return true }
        return false
    }
}
