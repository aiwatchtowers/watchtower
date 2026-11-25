import AppKit
import SwiftUI
import WatchtowerCore

/// The images an owner's Workchat line sent (`WorkchatOwnerImages`), in its bubble under the text. A paste (in the
/// attachments folder) is a thumbnail; a click opens the file in its default app (Preview). An image anywhere else is
/// a chip with its name that opens the same way: Watchtower never reads it, so a folder it has no access to (Desktop,
/// Documents, Downloads) never asks for permission. A paste that is gone (its session's folder swept) or cannot be
/// decoded is a chip too — never the raw path.
struct WorkchatOwnerImagesView: View {
    let images: [WorkchatOwnerImages.ImageFile]

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.compact) {
            ForEach(images, id: \.path) { image in
                if image.isAttachment {
                    WorkchatImageThumbnail(image: image)
                } else {
                    WorkchatImageChip(name: image.name, path: image.path, missing: false)
                }
            }
        }
    }

    /// Opens `path` in its default app (`NSWorkspace` hands the path over; Watchtower reads nothing); a path that
    /// will not open beeps. Returns whether it opened.
    @discardableResult
    static func open(_ path: String) -> Bool {
        let opened = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        if !opened { NSSound.beep() }
        return opened
    }
}

/// An image shown by its name: a photo icon and the file name. A missing paste is greyed and does nothing.
struct WorkchatImageChip: View {
    let name: String
    let path: String
    let missing: Bool

    var body: some View {
        Button { WorkchatOwnerImagesView.open(path) } label: {
            HStack(spacing: Spacing.compact) {
                Image(systemName: "photo").foregroundStyle(.secondary)
                Text(name).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Spacing.small)
            .background(Fill.rest, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(missing)
        .help(missing ? "\(name) is no longer on disk" : "Open \(name)")
    }
}

/// One pasted image of an owner line: decoded off the main actor, downscaled to the thumbnail's size.
struct WorkchatImageThumbnail: View {
    let image: WorkchatOwnerImages.ImageFile
    /// What decoding gave; nil while it runs. A thumbnail decoded before (the row scrolled back in) starts drawn.
    @State private var load: WorkbenchImageLoad?

    init(image: WorkchatOwnerImages.ImageFile) {
        self.image = image
        _load = State(initialValue: WorkchatThumbnailCache.cached(image.path).map(WorkbenchImageLoad.image))
    }

    /// The longest side a thumbnail is drawn at, in points; the decode asks twice that in pixels.
    static let maxSide: CGFloat = 220

    var body: some View {
        Group {
            switch load {
            case .image(let cgImage)?:
                Button { open() } label: {
                    // Decoded at twice the points (a Retina screen): drawn at half its pixels, at most `maxSide`.
                    Image(decorative: cgImage, scale: 2)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open \(image.name)")
                .accessibilityLabel("Image \(image.name)")
            case .missing?:
                WorkchatImageChip(name: image.name, path: image.path, missing: true)
            case .undecodable?:
                WorkchatImageChip(name: image.name, path: image.path, missing: false)
            case nil:
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Fill.card)
                    .frame(width: Self.maxSide / 2, height: Self.maxSide / 2)
            }
        }
        .task(id: image) {
            if case .image? = load { return }
            load = await WorkchatThumbnailCache.load(image)
        }
    }

    private func open() {
        WorkchatOwnerImagesView.open(image.path)
    }
}

/// The decoded thumbnails of the Workchat's owner images, by path: a feed row rebuilt on scroll or on the next read
/// draws at once instead of decoding again. A pasted file's name is unique to its paste, so a path keeps its image.
@MainActor
enum WorkchatThumbnailCache {
    private static let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        return cache
    }()

    static func cached(_ path: String) -> CGImage? {
        images.object(forKey: path as NSString)
    }

    /// The image's thumbnail, decoded off the main actor at twice `WorkchatImageThumbnail.maxSide` pixels and kept.
    static func load(_ image: WorkchatOwnerImages.ImageFile) async -> WorkbenchImageLoad {
        if let cached = cached(image.path) { return .image(cached) }
        let url = URL(fileURLWithPath: image.path)
        let pixels = Int(WorkchatImageThumbnail.maxSide * 2)
        let load = await Task.detached(priority: .userInitiated) {
            WorkbenchImageLoader.load(at: url, maxPixel: pixels)
        }.value
        if case let .image(decoded) = load { images.setObject(decoded, forKey: image.path as NSString) }
        return load
    }
}
