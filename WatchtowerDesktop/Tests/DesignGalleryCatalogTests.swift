import XCTest
import SwiftUI
import ViewInspector
@testable import DesignKitCatalog

/// The gallery window's taxonomy (#760, spec §2.3): every page sits in its
/// section, the sidebar search filters by title, and every public kit
/// component is shown on some page.
final class DesignGalleryCatalogTests: XCTestCase {
    func testEveryPageBelongsToItsSection() {
        let expected: [CatalogSection: [CatalogPage]] = [
            .foundations: [.colours, .spacing, .radius, .strokes, .typography, .icons, .motion],
            .components: [.actions, .selection, .inputs, .display, .containers],
            .patterns: [.settings, .panels, .popover]
        ]
        for section in CatalogSection.allCases {
            XCTAssertEqual(section.pages, expected[section], "\(section)")
            XCTAssertTrue(section.pages.allSatisfy { $0.section == section }, "\(section)")
        }
        XCTAssertEqual(CatalogSection.allCases.flatMap(\.pages), CatalogPage.allCases)
    }

    func testSearchFiltersPagesByTitle() {
        XCTAssertEqual(CatalogPage.filtered(by: "spa"), [.spacing])
        XCTAssertEqual(CatalogPage.filtered(by: "SPA"), [.spacing])
        XCTAssertEqual(CatalogPage.filtered(by: ""), CatalogPage.allCases)
        XCTAssertEqual(CatalogPage.filtered(by: "  "), CatalogPage.allCases)
        XCTAssertEqual(CatalogPage.filtered(by: "zzz"), [])
    }

    /// Hand-written on purpose: a component added to the kit without a page
    /// fails here until it is listed both here and on its page.
    func testEveryKitComponentAppearsOnAPage() {
        let kit: Set<String> = [
            // Foundations
            "Surface", "Fill", "Tone", "ChipTint", "Spacing", "Radius", "Stroke", "IconSize",
            "Motion", "FloatingShadow", "detailBackground", "panelBackground",
            // Components
            "kitPrimary", "kitSecondary", "kitQuiet", "kitDestructive", "kitIcon", "KitButtonMetrics",
            "FloatingButtonLabel", "SegmentedToggleStyle", "KitSegmentedPicker", "segmentCapsule",
            "KitFieldStyle", "Chip", "CountBadge", "OutlineTag", "MenuLabel", "SectionHeader",
            "card", "kitRow",
            // Patterns
            "SettingsSection", "SettingRow", "PanelSplit", "PanelResizeHandle", "panelSurface",
            "panelTab", "panelListStyle", "workspaceListStyle", "clearPlainList", "popoverSurface"
        ]
        XCTAssertEqual(Set(CatalogPage.componentsShown), kit)
        XCTAssertEqual(CatalogPage.componentsShown.count, kit.count, "a component is listed on two pages")
    }

    func testUsageLineShowsItsCode() throws {
        let line = UsageLine(".buttonStyle(.kitSecondary)")
        XCTAssertNoThrow(try line.inspect().find(text: ".buttonStyle(.kitSecondary)"))
    }
}
