import AppKit
import SwiftUI
import WatchtowerCore

/// The go-to-definition menu (spec §8.2): an `NSMenu` at the click with
/// "word — N definitions", one row per candidate (kind badge, `Type.name`,
/// `path:line` in a secondary colour), a separator and "Show All Usages…".
@MainActor
final class DefinitionMenuController: NSObject, DefinitionMenuPresenting {
    private static let usagesTag = -1
    private var picked: Int?

    func pickDefinition(header: String, choices: [DefinitionChoice], at anchor: DefinitionMenuAnchor?) async -> DefinitionMenuPick {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let appearance = anchor?.view?.effectiveAppearance ?? NSApp.effectiveAppearance
        let scheme: ColorScheme = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        for (index, choice) in choices.enumerated() {
            let item = NSMenuItem(title: "", action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.attributedTitle = Self.rowTitle(choice)
            item.image = Self.badgeImage(choice.kind, scheme: scheme)
            item.toolTip = choice.location
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let usages = NSMenuItem(title: "Show All Usages…", action: #selector(choose(_:)), keyEquivalent: "")
        usages.target = self
        usages.tag = Self.usagesTag
        menu.addItem(usages)

        picked = nil
        if let view = anchor?.view, let point = anchor?.point {
            menu.popUp(positioning: nil, at: point, in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        defer { picked = nil }
        switch picked {
        case .none: return .dismissed
        case .some(Self.usagesTag): return .showAllUsages
        case let .some(index): return .choice(index)
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        picked = sender.tag
    }

    private static func rowTitle(_ choice: DefinitionChoice) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: choice.title, attributes: [.font: font])
        title.append(NSAttributedString(string: "   \(choice.location)", attributes: [
            .font: NSFont.menuFont(ofSize: font.pointSize - 2),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        return title
    }

    /// The kind badge as the menu's image; a text line for a text-search row.
    private static func badgeImage(_ kind: CodeSymbolKind?, scheme: ColorScheme) -> NSImage? {
        guard let kind else {
            return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Text match")
        }
        return CodeKindBadge.menuImage(kind, scheme: scheme)
    }
}
