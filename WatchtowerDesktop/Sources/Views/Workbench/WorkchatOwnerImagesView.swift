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
    /// The file would not open (gone meanwhile): the owner looks again.
    var onOpenFailed: () -> Void = {}

    var body: some View {
        Button { if !WorkchatOwnerImagesView.open(path) { onOpenFailed() } } label: {
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
    /// What decoding gave; nil while it runs. A file gone starts as missing, a thumbnail decoded before (the row
    /// scrolled back in) starts drawn.
    @State private var load: WorkbenchImageLoad?
    /// Bumped when a click finds the file will not open: the load runs again, so a file gone meanwhile turns into
    /// the missing chip.
    @State private var attempt = 0

    init(image: WorkchatOwnerImages.ImageFile) {
        self.image = image
        _load = State(initialValue: WorkchatThumbnailCache.cached(image.path))
    }

    /// The longest side a thumbnail is drawn at, in points; the decode asks twice that in pixels.
    static let maxSide: CGFloat = 220

    private struct LoadKey: Hashable {
        let path: String
        let attempt: Int
    }

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
                WorkchatImageChip(name: image.name, path: image.path, missing: false) { attempt += 1 }
            case nil:
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Fill.card)
                    .frame(width: Self.maxSide / 2, height: Self.maxSide / 2)
            }
        }
        .task(id: LoadKey(path: image.path, attempt: attempt)) {
            if attempt == 0, case .image? = load { return }
            load = await WorkchatThumbnailCache.load(image.path)
        }
    }

    private func open() {
        if !WorkchatOwnerImagesView.open(image.path) { attempt += 1 }
    }
}

/// The decoded thumbnails of the Workchat's pasted images, by path and modification time: a feed row rebuilt on
/// scroll or on the next read draws at once instead of decoding again, and a file gone or rewritten is never drawn
/// from an old decode. Only the attachments folder's files come here (`WorkchatOwnerImages.ImageFile.isAttachment`).
@MainActor
enum WorkchatThumbnailCache {
    private static let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        return cache
    }()

    /// The file's key, its path and modification time; nil when it is not on disk.
    private static func key(_ path: String) -> NSString? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(modified) \(path)" as NSString
    }

    /// What a thumbnail starts as: `.missing` when the file is gone, its image when this version of it was decoded
    /// before, nil when it has to be decoded.
    static func cached(_ path: String) -> WorkbenchImageLoad? {
        guard let key = key(path) else { return .missing }
        return images.object(forKey: key).map(WorkbenchImageLoad.image)
    }

    /// The file's thumbnail, decoded off the main actor at twice `WorkchatImageThumbnail.maxSide` pixels and kept; a
    /// file that does not decode is not kept, so it is tried again next time.
    static func load(_ path: String) async -> WorkbenchImageLoad {
        if let cached = cached(path) { return cached }
        guard let key = key(path) else { return .missing }
        let url = URL(fileURLWithPath: path)
        let pixels = Int(WorkchatImageThumbnail.maxSide * 2)
        let load = await Task.detached(priority: .userInitiated) {
            WorkbenchImageLoader.load(at: url, maxPixel: pixels)
        }.value
        if case let .image(decoded) = load { images.setObject(decoded, forKey: key) }
        return load
    }
}
