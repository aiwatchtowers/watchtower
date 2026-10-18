import SwiftUI

/// The dev-build window that shows every kit token and component on one page
/// (style guide #719). Each component task appends a `GallerySection`.
struct DesignSystemGallery: View {
    static let sceneID = "design-gallery"

    var body: some View {
        ScrollView { DesignSystemGalleryContent() }
            .detailBackground()
    }
}

/// The gallery's sections without the scroll view, which the design shot
/// renders directly (a scroll view's layer does not render its full width).
struct DesignSystemGalleryContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.wide) {
            GallerySection(title: "Tokens") { GalleryTokens() }
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled block of the gallery.
struct GallerySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(title).font(.title3).fontWeight(.semibold)
            content
        }
    }
}

/// The scale tokens, each drawn with its name.
private struct GalleryTokens: View {
    private let spacings: [(String, CGFloat)] = [
        ("tight", Spacing.tight), ("small", Spacing.small), ("compact", Spacing.compact),
        ("regular", Spacing.regular), ("cozy", Spacing.cozy), ("medium", Spacing.medium),
        ("large", Spacing.large), ("page", Spacing.page), ("wide", Spacing.wide), ("hero", Spacing.hero)
    ]
    private let radii: [(String, CGFloat)] = [
        ("mark", Radius.mark), ("control", Radius.control), ("row", Radius.row),
        ("container", Radius.container), ("bubble", Radius.bubble), ("pill", Radius.pill)
    ]
    private let fills: [(String, Color)] = [
        ("rest", Fill.rest), ("card", Fill.card), ("hover", Fill.hover),
        ("selected", Fill.selected), ("on", Fill.on)
    ]
    private let tones: [(String, Color)] = [
        ("blue", Tone.status("blue")), ("teal", Tone.status("teal")), ("red", Tone.status("red")),
        ("green", Tone.status("green")), ("gray", Tone.status("gray")), ("purple", Tone.status("purple")),
        ("high", Tone.priority("high")), ("medium", Tone.priority("medium")), ("low", Tone.priority("low"))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            group("Spacing") {
                ForEach(spacings, id: \.0) { name, value in
                    HStack(spacing: Spacing.regular) {
                        Text("\(name) \(Int(value))").font(.caption).frame(width: 90, alignment: .leading)
                        Rectangle().fill(Color.accentColor).frame(width: value, height: Spacing.regular)
                    }
                }
            }
            group("Radius") {
                HStack(spacing: Spacing.medium) {
                    ForEach(radii, id: \.0) { name, value in
                        VStack(spacing: Spacing.small) {
                            RoundedRectangle(cornerRadius: value)
                                .fill(Fill.card)
                                .overlay(RoundedRectangle(cornerRadius: value).stroke(Stroke.hairlineColor, lineWidth: Stroke.hairline))
                                .frame(width: 56, height: 56)
                            Text("\(name) \(Int(value))").font(.caption2)
                        }
                    }
                }
            }
            group("Fills") {
                HStack(spacing: Spacing.medium) {
                    ForEach(fills, id: \.0) { name, color in
                        VStack(spacing: Spacing.small) {
                            RoundedRectangle(cornerRadius: Radius.row).fill(color).frame(width: 72, height: 40)
                            Text(name).font(.caption2)
                        }
                    }
                }
            }
            group("Tones") {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    toneRow(Array(tones.prefix(6)))
                    toneRow(Array(tones.suffix(3)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toneRow(_ row: [(String, Color)]) -> some View {
        HStack(spacing: Spacing.compact) {
            ForEach(row, id: \.0) { name, color in
                Text(name)
                    .font(.caption)
                    .padding(.horizontal, Spacing.regular)
                    .padding(.vertical, Spacing.small)
                    .background(color.opacity(ChipTint.fillOpacity), in: Capsule())
                    .overlay(Capsule().stroke(color.opacity(ChipTint.strokeOpacity), lineWidth: ChipTint.strokeWidth))
            }
        }
        .padding(.trailing, Spacing.tight)
    }

    private func group<Body: View>(_ title: String, @ViewBuilder _ body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            body()
        }
    }
}
