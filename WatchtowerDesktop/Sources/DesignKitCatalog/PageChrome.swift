import AppKit
import DesignKit
import SwiftUI

// MARK: - Options

/// The toolbar's Appearance choice: the system's, or forced light or dark.
enum GalleryAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The AppKit appearance behind it: `NSColor.detailBackground` and the
    /// other dynamic AppKit colours resolve against the window's appearance,
    /// which `.preferredColorScheme` alone leaves to the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The toolbar's Control size choice.
enum GalleryControlSize: String, CaseIterable, Identifiable {
    case mini, small, regular, large

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var controlSize: ControlSize {
        switch self {
        case .mini: .mini
        case .small: .small
        case .regular: .regular
        case .large: .large
        }
    }
}

/// The toolbar's Surface choice: what the page sits on.
enum GallerySurface: String, CaseIterable, Identifiable {
    case detail, window, popover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .detail: "Detail"
        case .window: "Window"
        case .popover: "Popover"
        }
    }
}

/// What the toolbar sets for every page. The defaults are what a page shows
/// in its shot: system appearance, regular controls, the detail backdrop.
struct GalleryOptions: Equatable {
    var appearance: GalleryAppearance = .system
    var controlSize: GalleryControlSize = .regular
    var surface: GallerySurface = .detail
    var disabled = false
}

extension EnvironmentValues {
    /// The toolbar's Disabled switch: each `Sample` disables its own content,
    /// so the usage line under it stays selectable.
    @Entry var gallerySamplesDisabled = false
    /// Set by a shot: pages with a live clock draw this moment instead, so
    /// the shot is the same on every run.
    @Entry var galleryFrozenDate: Date?
}

// MARK: - Toolbar

/// The page toolbar (spec §2.2): Appearance, Control size, Surface, Disabled.
struct GalleryToolbar: ToolbarContent {
    @Binding var appearance: GalleryAppearance
    @Binding var controlSize: GalleryControlSize
    @Binding var surface: GallerySurface
    @Binding var disabled: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Appearance", selection: $appearance) {
                ForEach(GalleryAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Appearance")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Control size", selection: $controlSize) {
                ForEach(GalleryControlSize.allCases) { Text($0.title).tag($0) }
            }
            .help("Control size")
            Picker("Surface", selection: $surface) {
                ForEach(GallerySurface.allCases) { Text($0.title).tag($0) }
            }
            .help("The surface the page sits on")
            Toggle(isOn: $disabled) {
                Label("Disabled", systemImage: "nosign")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(disabled ? "Enable the samples" : "Disable every sample")
        }
    }
}

// MARK: - Page

/// One page as the window shows it, without the scroll view or the surface
/// behind it (a shot renders this directly and paints its own): the title
/// (shots only) and summary, then the page's samples under the toolbar's control size and
/// disabled state.
struct CatalogPageBody: View {
    let page: CatalogPage
    var options = GalleryOptions()
    /// The window shows the title in its title bar; a shot has none.
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.wide) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                if showsTitle {
                    Text(page.title).font(.title2.weight(.semibold))
                }
                Text(page.summary).font(.callout).foregroundStyle(.secondary)
            }
            page.content()
                .controlSize(options.controlSize.controlSize)
                .environment(\.gallerySamplesDisabled, options.disabled)
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

extension View {
    /// Paints the chosen surface behind the page. The popover choice also
    /// sets `popoverSurface()`, so the kit's fields turn translucent as they
    /// do in a real popover.
    @ViewBuilder
    func gallerySurface(_ surface: GallerySurface) -> some View {
        switch surface {
        case .detail: detailBackground()
        case .window: panelBackground()
        case .popover: popoverSurface().background(PopoverMaterial())
        }
    }
}

/// The system popover material, blended with the page under it as a
/// popover over the window would be.
struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Samples

/// A titled group of samples on a page.
struct PageSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            Text(title).font(.title3.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One sample: a caption naming it, the live sample (disabled by the
/// toolbar's switch), and the code that makes it.
struct Sample<Content: View>: View {
    let title: String
    let usage: String?
    @ViewBuilder let content: Content

    @Environment(\.gallerySamplesDisabled) private var disabled

    init(_ title: String, usage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.usage = usage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content.disabled(disabled)
            if let usage { UsageLine(usage) }
        }
    }
}

/// The one line of code under a sample: monospaced and selectable, to copy.
struct UsageLine: View {
    let code: String

    init(_ code: String) {
        self.code = code
    }

    var body: some View {
        Text(code)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
