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
            "followSelection": "a ScrollViewProxy helper: scrolling, nothing drawn",
            "onPopoverSurface": "an environment flag set by popoverSurface(), nothing drawn"
        ]
        let shown = Set(CatalogPage.componentsShown)
        XCTAssertEqual(CatalogPage.componentsShown.count, shown.count, "a component is listed on two pages")
        XCTAssertEqual(kit.subtracting(shown).subtracting(excluded.keys), [], "public kit API on no page")
        XCTAssertEqual(shown.subtracting(kit), [], "a page lists a name the kit does not make public")
        XCTAssertEqual(Set(excluded.keys).subtracting(kit), [], "a stale exclusion")
        XCTAssertEqual(Set(excluded.keys).intersection(shown), [], "an excluded name is also listed on a page")
    }

    /// The names of `Sources/DesignKit`'s top-level public declarations, and
    /// of the public members of its extensions (`.card()`, `.kitPrimary`,
    /// every member of a `public extension`), plus those of the Kit's
    /// `WatchtowerDesign`, the tokens DesignKit re-exports. A type's own
    /// members belong to the type and are not listed.
    private static func publicKitNames() throws -> Set<String> {
        let desktop = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dirs = [
            desktop.appendingPathComponent("Sources/DesignKit"),
            desktop.appendingPathComponent("../WatchtowerKit/Sources/WatchtowerDesign").standardized
        ]
        let files = try dirs.flatMap { dir in
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        }
        .filter { $0.pathExtension == "swift" }
        var names = Set<String>()
        for file in files {
            names.formUnion(try publicNames(in: String(contentsOf: file, encoding: .utf8)))
        }
        return names
    }

    /// Leading attributes (`@Entry`, `@ViewBuilder`, `@available(macOS 14, *)`).
    private static let attributes = #"(?:@\w+(?:\([^)]*\))?\s+)*"#
    private static let declaration = #"(?:static\s+|class\s+)?(?:func|var|let)\s+(\w+)"#

    static func publicNames(in source: String) throws -> Set<String> {
        let topLevel = try NSRegularExpression(
            pattern: "^" + attributes + #"public\s+(?:final\s+)?(?:struct|enum|class|protocol|actor|typealias|func|var|let)\s+(\w+)"#)
        let extensionHead = try NSRegularExpression(pattern: "^" + attributes + #"(public\s+)?extension\s"#)
        let publicMember = try NSRegularExpression(pattern: "^    " + attributes + #"public\s+"# + declaration)
        let anyMember = try NSRegularExpression(pattern: "^    " + attributes + declaration)
        let attributesOnly = try NSRegularExpression(pattern: #"^(?:@\w+(?:\([^)]*\))?\s*)+$"#)
        var names = Set<String>()
        var inExtension = false
        var publicExtension = false
        for line in source.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let first = line.first, !first.isWhitespace, first != "}", !line.hasPrefix("//"),
               attributesOnly.firstMatch(in: line, range: range) == nil {
                let head = extensionHead.firstMatch(in: line, range: range)
                inExtension = head != nil
                publicExtension = head.map { $0.range(at: 1).location != NSNotFound } ?? false
            }
            let regex = !inExtension ? topLevel : publicExtension ? anyMember : publicMember
            if let match = regex.firstMatch(in: line, range: range), let name = Range(match.range(at: 1), in: line) {
                names.insert(String(line[name]))
            }
        }
        return names
    }

    /// Every way a declaration can be public is caught, and a type's own
    /// members and non-public extension members are not.
    func testScanFindsEveryPublicForm() throws {
        let source = """
        public struct ProbeBadge: View {
            public static let size: CGFloat = 4
        }
        public final class ProbeClass {}
        public protocol ProbeProtocol {}
        struct Internal {}
        extension View {
            public func probeModifier() -> some View { self }
            @ViewBuilder public func probeBuilder() -> some View { self }
            public var probeVar: Int { 0 }
            func internalHelper() {}
        }
        @MainActor public enum ProbeEnum {}
        extension View {
            func internalAfterAnExtension() {}
        }
        @MainActor
        public struct ProbeAttributedOnItsOwnLine {
            public func ownMember() {}
        }
        extension EnvironmentValues {
            @Entry public var probeEntry = false
        }
        extension Color {
            public static let probeColor = Color.red
        }
        public extension View {
            func probeImplicit() -> some View { self }
            static var probeImplicitStatic: Int { 0 }
        }
        """
        XCTAssertEqual(try Self.publicNames(in: source), [
            "ProbeBadge", "ProbeClass", "ProbeProtocol", "ProbeEnum", "ProbeAttributedOnItsOwnLine",
            "probeModifier", "probeBuilder", "probeVar", "probeEntry", "probeColor",
            "probeImplicit", "probeImplicitStatic"
        ])
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
