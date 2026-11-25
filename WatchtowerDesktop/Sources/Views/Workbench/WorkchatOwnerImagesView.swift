import AppKit
import SwiftUI
import WatchtowerCore

/// The images an owner's Workchat line sent (`WorkchatOwnerImages`), in its bubble under the text: a thumbnail per
/// image, a click opens the file in its default app (Preview). A file that is gone (swept after 7 days) or cannot be
/// decoded is a small chip with its name — never the raw path.
struct WorkchatOwnerImagesView: View {
    let images: [WorkchatOwnerImages.ImageFile]

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.compact) {
            ForEach(images, id: \.path) { WorkchatImageThumbnail(image: $0) }
        }
    }
}

/// One image of an owner line: decoded off the main actor, downscaled to the thumbnail's size.
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
                chip(missing: true)
            case .undecodable?:
                chip(missing: false)
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

    /// The fallback: a photo icon and the file's name; a file still there (not decodable) still opens on a click.
    private func chip(missing: Bool) -> some View {
        Button { open() } label: {
            HStack(spacing: Spacing.compact) {
                Image(systemName: "photo").foregroundStyle(.secondary)
                Text(image.name).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Spacing.small)
            .background(Fill.rest, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(missing)
        .help(missing ? "\(image.name) is no longer on disk" : "Open \(image.name)")
    }

    private func open() {
        NSWorkspace.shared.open(URL(fileURLWithPath: image.path))
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
        guard image.exists else { return .missing }
        let url = URL(fileURLWithPath: image.path)
        let pixels = Int(WorkchatImageThumbnail.maxSide * 2)
        let load = await Task.detached(priority: .userInitiated) {
            WorkbenchImageLoader.load(at: url, maxPixel: pixels)
        }.value
        if case let .image(decoded) = load { images.setObject(decoded, forKey: image.path as NSString) }
        return load
    }
}
