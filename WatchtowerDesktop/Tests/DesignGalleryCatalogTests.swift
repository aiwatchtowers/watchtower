import XCTest
import SwiftUI
import ViewInspector
@testable import DesignKitCatalog

/// The gallery window's taxonomy (#760, spec §2.3): every page sits in its
/// section, the sidebar search filters by title, and every public kit
/// component (read from the kit's source) is shown on some page.
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

    /// The kit's public visual API, read from its source: a new public
    /// component that is on no page fails here until a page lists it.
    func testEveryKitComponentAppearsOnAPage() throws {
        let kit = try Self.publicKitNames()
        XCTAssertFalse(kit.isEmpty, "the scan found no public kit API")
        // Public, but not something a page can show on its own.
        let excluded: [String: String] = [
            // A style type is shown through its accessor (`.kitPrimary`, `.kit`).
            "KitPrimaryButtonStyle": "shown as kitPrimary",
            "KitSecondaryButtonStyle": "shown as kitSecondary",
            "KitQuietButtonStyle": "shown as kitQuiet",
            "KitDestructiveButtonStyle": "shown as kitDestructive",
            "KitIconButtonStyle": "shown as kitIcon",
            "KitFieldStyle": "shown as kit",
            "PanelTab": "the modifier behind panelTab(isSelected:)",
            "followSelection": "a ScrollViewProxy helper: scrolling, nothing drawn"
        ]
        let shown = Set(CatalogPage.componentsShown)
        XCTAssertEqual(CatalogPage.componentsShown.count, shown.count, "a component is listed on two pages")
        XCTAssertEqual(kit.subtracting(shown).subtracting(excluded.keys), [], "public kit API on no page")
        XCTAssertEqual(shown.subtracting(kit), [], "a page lists a name the kit does not make public")
        XCTAssertEqual(Set(excluded.keys).subtracting(kit), [], "a stale exclusion")
        XCTAssertEqual(Set(excluded.keys).intersection(shown), [], "an excluded name is also listed on a page")
    }

    /// The names of `Sources/DesignKit`'s top-level public types, and of the
    /// public members of its extensions (`.card()`, `.kitPrimary`). A type's
    /// own members belong to the type and are not listed.
    private static func publicKitNames() throws -> Set<String> {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DesignKit")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let topLevel = try NSRegularExpression(pattern: #"^public (?:struct|enum) (\w+)"#)
        let member = try NSRegularExpression(pattern: #"^    public (?:func|static var|static func) (\w+)"#)
        var names = Set<String>()
        for file in files {
            var inExtension = false
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                if let first = line.first, !first.isWhitespace, first != "}", !line.hasPrefix("//") {
                    inExtension = line.hasPrefix("extension ")
                }
                let range = NSRange(line.startIndex..., in: line)
                let regex = inExtension ? member : topLevel
                if let match = regex.firstMatch(in: line, range: range), let name = Range(match.range(at: 1), in: line) {
                    names.insert(String(line[name]))
                }
            }
        }
        return names
    }

    func testUsageLineIsMonospacedAndSelectable() throws {
        let line = UsageLine(".buttonStyle(.kitSecondary)")
        let text = try line.inspect().find(text: ".buttonStyle(.kitSecondary)")
        XCTAssertEqual(try text.attributes().font(), .system(.caption, design: .monospaced))
        // ViewInspector cannot read text selection; the modifier shows in the body's type.
        let bodyType = String(reflecting: type(of: line.body))
        XCTAssertTrue(bodyType.contains("EnabledTextSelectability"), "the usage line is not selectable: \(bodyType)")
    }
}
