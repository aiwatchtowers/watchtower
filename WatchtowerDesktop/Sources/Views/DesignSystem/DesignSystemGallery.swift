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
            GallerySection(title: "Buttons") { GalleryButtons() }
            GallerySection(title: "Segmented toggle") { GallerySegments() }
            GallerySection(title: "Segmented picker") { GalleryPicker() }
            GallerySection(title: "Chips and tags") { GalleryChips() }
            GallerySection(title: "Section header") { GallerySectionHeaders() }
            GallerySection(title: "Card") { GalleryCards() }
            GallerySection(title: "Floating button") { GalleryFloatingButton() }
            GalleryNewComponents()
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

/// Every promoted button style, enabled and disabled, small and regular where
/// the style reacts to the control size.
private struct GalleryButtons: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            row("kitPrimary") {
                Button("Save") {}.buttonStyle(.kitPrimary)
                Button("Save") {}.buttonStyle(.kitPrimary).disabled(true)
            }
            row("kitDestructive, small") {
                Button("Stop") {}.buttonStyle(.kitDestructive).controlSize(.small)
                Button("Stop") {}.buttonStyle(.kitDestructive).controlSize(.small).disabled(true)
            }
            row("kitDestructive, regular") {
                Button("Stop") {}.buttonStyle(.kitDestructive)
                Button("Stop") {}.buttonStyle(.kitDestructive).disabled(true)
            }
            row("kitIcon, off / on / disabled") {
                Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.kitIcon(isOn: false))
                Button {} label: { Image(systemName: "rectangle.split.2x1") }.buttonStyle(.kitIcon(isOn: true))
                Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.kitIcon(isOn: false)).disabled(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Body: View>(_ name: String, @ViewBuilder _ body: () -> Body) -> some View {
        HStack(spacing: Spacing.medium) {
            Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
            body()
        }
    }
}

/// The header segmented toggle: off, on and the hovered fill.
private struct GallerySegments: View {
    @State private var states = [false, true, false]

    var body: some View {
        HStack(spacing: Spacing.small) {
            ForEach(0..<3, id: \.self) { index in
                Toggle(isOn: $states[index]) {
                    Label(["Board", "Terminal", "Files"][index], systemImage: ["rectangle.split.3x1", "terminal", "folder"][index])
                }
                .toggleStyle(SegmentedToggleStyle(joinsChevron: index == 1, isHovered: index == 2) { _ in })
            }
        }
    }
}

/// The single-choice capsule: one segment on at a time.
private struct GalleryPicker: View {
    @State private var choice = "Week"

    var body: some View {
        KitSegmentedPicker(selection: $choice, segments: [
            KitSegment(value: "Day", title: "Day"),
            KitSegment(value: "Week", title: "Week", systemImage: "calendar"),
            KitSegment(value: "Month", title: "Month")
        ])
    }
}

/// The four capsule recipes, each with its own values.
private struct GalleryChips: View {
    var body: some View {
        HStack(spacing: Spacing.medium) {
            Chip(text: "HIGH", color: .red)
            Chip(text: "In progress", color: .blue, dot: true)
            CountBadge(text: "#42")
            OutlineTag(text: "Codex")
            MenuLabel(text: "In progress", systemImage: "circle.lefthalf.filled", color: .blue)
            MenuLabel(text: "Done", systemImage: "checkmark.circle.fill", color: .green, isMenu: false)
        }
    }
}

private struct GallerySectionHeaders: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            SectionHeader(title: "Sub-tasks", systemImage: "checklist", count: 3)
            SectionHeader(title: "Description", systemImage: "text.alignleft")
        }
    }
}

/// The card outline, resting and selected, over a caller-owned fill.
private struct GalleryCards: View {
    var body: some View {
        HStack(spacing: Spacing.medium) {
            ForEach([false, true], id: \.self) { selected in
                Text(selected ? "Selected" : "Resting")
                    .padding(Spacing.medium)
                    .frame(width: 160, alignment: .leading)
                    .background(Fill.card)
                    .card(selected: selected)
            }
        }
    }
}

private struct GalleryFloatingButton: View {
    var body: some View {
        FloatingButtonLabel(title: "Jump to latest", systemImage: "arrow.down")
    }
}
