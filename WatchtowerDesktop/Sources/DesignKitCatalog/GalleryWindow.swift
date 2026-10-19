import AppKit
import DesignKit
import SwiftUI

/// The design gallery window (#760, spec §2.2): the taxonomy in the sidebar,
/// grouped by section and filtered by the search field, and the chosen page
/// under the toolbar. The page, appearance, control size and surface are
/// remembered, and each can be set at launch as a defaults argument
/// (`swift run DesignGallery -gallery.page panels -gallery.appearance dark`).
public struct GalleryRootView: View {
    @AppStorage("gallery.page") private var page: CatalogPage = .colours
    @AppStorage("gallery.appearance") private var appearance: GalleryAppearance = .system
    @AppStorage("gallery.controlSize") private var controlSize: GalleryControlSize = .regular
    @AppStorage("gallery.surface") private var surface: GallerySurface = .detail
    @State private var disabled = false
    @State private var query = ""

    public init() {}

    private var options: GalleryOptions {
        var options = GalleryOptions()
        options.appearance = appearance
        options.controlSize = controlSize
        options.surface = surface
        options.disabled = disabled
        return options
    }

    /// The sidebar's selection; a cleared selection keeps the page shown.
    private var selection: Binding<CatalogPage?> {
        Binding(get: { page }, set: { if let new = $0 { page = new } })
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ScrollView {
                CatalogPageBody(page: page, options: options, showsTitle: false)
            }
            .gallerySurface(surface)
            .navigationTitle(page.title)
            .navigationSubtitle(page.section.title)
            .toolbar {
                GalleryToolbar(appearance: $appearance, controlSize: $controlSize,
                               surface: $surface, disabled: $disabled)
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .onChange(of: appearance, initial: true) { _, new in
            NSApp.appearance = new.nsAppearance
        }
    }

    private var sidebar: some View {
        let shown = CatalogPage.filtered(by: query)
        return List(selection: selection) {
            ForEach(CatalogSection.allCases, id: \.self) { section in
                let pages = section.pages.filter(shown.contains)
                if !pages.isEmpty {
                    Section(section.title) {
                        ForEach(pages) { Text($0.title).tag($0) }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Filter pages")
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
    }
}
