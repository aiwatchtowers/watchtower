import SwiftUI

/// The gallery's three top-level groups (spec §2.3): the tokens, the
/// components built from them, and the patterns the components make up.
public enum CatalogSection: CaseIterable {
    case foundations, components, patterns

    public var title: String {
        switch self {
        case .foundations: "Foundations"
        case .components: "Components"
        case .patterns: "Patterns"
        }
    }

    /// The section's pages, in sidebar order.
    public var pages: [CatalogPage] {
        CatalogPage.allCases.filter { $0.section == self }
    }
}

/// One leaf of the gallery's sidebar, one page of the window (spec §2.3).
/// The taxonomy lives only here: a new kit component adds its name to the
/// `components` of exactly one page and a sample to that page's view.
public enum CatalogPage: String, CaseIterable, Identifiable {
    // Foundations
    case colours, spacing, radius, strokes, typography, icons, motion
    // Components
    case actions, selection, inputs, display, containers
    // Patterns
    case settings, panels, popover

    public var id: String { rawValue }

    public var section: CatalogSection {
        switch self {
        case .colours, .spacing, .radius, .strokes, .typography, .icons, .motion: .foundations
        case .actions, .selection, .inputs, .display, .containers: .components
        case .settings, .panels, .popover: .patterns
        }
    }

    public var title: String {
        switch self {
        case .colours: "Colour & surfaces"
        case .spacing: "Spacing"
        case .radius: "Radius"
        case .strokes: "Strokes"
        case .typography: "Typography"
        case .icons: "Icons"
        case .motion: "Motion & shadow"
        case .actions: "Actions"
        case .selection: "Selection"
        case .inputs: "Inputs"
        case .display: "Display"
        case .containers: "Containers"
        case .settings: "Settings"
        case .panels: "Panels"
        case .popover: "Popover"
        }
    }

    /// The page's one-line purpose, under its title.
    var summary: String {
        switch self {
        case .colours: "The app's surfaces, the neutral and accent fills, and the status and priority tones."
        case .spacing: "The closed spacing scale: padding and stack spacing come from these steps only."
        case .radius: "Corner radii by role. Chips and badges are capsules."
        case .strokes: "The hairline between panes and the accent selection outline."
        case .typography: "The text roles screens use: system text styles with a weight, never a size."
        case .icons: "Glyph sizes for chevrons, headers and the composer."
        case .motion: "The two standard animations and the one shadow (floating buttons only)."
        case .actions: "Buttons: one prominent action per screen, soft buttons for the rest."
        case .selection: "Pick one of a few values, or toggle independent views, in the header capsule."
        case .inputs: "The kit's single-line field, at rest, focused and over a popover."
        case .display: "Small read-only marks: chips, badges, tags, menu labels and section titles."
        case .containers: "A soft card for a group, a selectable row for a list."
        case .settings: "A settings block of a new window: sections on soft cards, switches trailing."
        case .panels: "Main content beside a resizable side panel, and a panel of tab rows."
        case .popover: "A popover's body over the system material, with a field and its one action."
        }
    }

    /// The public kit names this page shows, each on exactly one page: a
    /// type, or for a style the accessor it is used through (`kitPrimary`,
    /// `kit`). `DesignGalleryCatalogTests` checks them against the kit's source.
    var components: [String] {
        switch self {
        case .colours: ["Surface", "Fill", "Tone", "ChipTint", "detailBackground", "panelBackground"]
        case .spacing: ["Spacing", "PaneWidth", "ListLayout"]
        case .radius: ["Radius"]
        case .strokes: ["Stroke"]
        case .typography: ["Tracking"]
        case .icons: ["IconSize"]
        case .motion: ["Motion", "FloatingShadow"]
        case .actions: ["kitPrimary", "kitSecondary", "kitQuiet", "kitDestructive", "kitIcon",
                        "FloatingButtonLabel"]
        case .selection: ["SegmentedToggleStyle", "KitSegmentedPicker", "KitSegment", "segmentCapsule"]
        case .inputs: ["kit"]
        case .display: ["Chip", "CountBadge", "OutlineTag", "MenuLabel", "SectionHeader"]
        case .containers: ["card", "kitRow"]
        case .settings: ["SettingsSection", "SettingRow", "ManagedByOrganizationBadge", "managedByOrganization"]
        case .panels: ["PanelSplit", "PanelSplitWidth", "PanelResizeHandle", "panelSurface", "panelTab",
                       "panelListStyle", "workspaceListStyle", "clearPlainList"]
        case .popover: ["popoverSurface"]
        }
    }

    /// Every kit name some page shows, in page order.
    public static var componentsShown: [String] {
        Self.allCases.flatMap(\.components)
    }

    /// The pages whose title contains `query`, ignoring case; a blank query
    /// keeps them all (the sidebar search).
    public static func filtered(by query: String) -> [Self] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Self.allCases }
        return Self.allCases.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    /// The page's samples, without its title or scroll view.
    @MainActor @ViewBuilder
    public func content() -> some View {
        switch self {
        case .colours: ColoursPage()
        case .spacing: SpacingPage()
        case .radius: RadiusPage()
        case .strokes: StrokesPage()
        case .typography: TypographyPage()
        case .icons: IconsPage()
        case .motion: MotionPage()
        case .actions: ActionsPage()
        case .selection: SelectionPage()
        case .inputs: InputsPage()
        case .display: DisplayPage()
        case .containers: ContainersPage()
        case .settings: SettingsPatternPage()
        case .panels: PanelsPage()
        case .popover: PopoverPage()
        }
    }
}
