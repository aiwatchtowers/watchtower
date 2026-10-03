import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerCore

/// What was picked in a jump bar menu.
enum JumpBarPick: Equatable {
    case file(String)
    case symbol(CodeSymbol)
}

/// The `NSMenu` behind one jump bar segment (spec §8.4), built from the
/// Core `JumpBarMenuContent`: a folder's subfolders (submenus filled when
/// opened) and files, the symbols beside a type or method, or the file's
/// symbol list under a filter field (the last segment, ⌃6). The current
/// file or symbol is checked.
@MainActor
final class JumpBarMenu: NSObject, NSMenuDelegate, NSSearchFieldDelegate {
    let menu = NSMenu()
    private(set) var filterField: NSSearchField?
    private let files: [String]
    private let currentFile: String
    private let currentSymbol: CodeSymbol?
    private let scheme: ColorScheme
    private let onPick: (JumpBarPick) -> Void
    private var picks: [JumpBarPick] = []
    private var symbolItems: [(item: NSMenuItem, row: JumpBarSymbolRow)] = []
    /// Folder submenus not filled yet, by menu.
    private var pendingFolders: [ObjectIdentifier: String] = [:]
    private var badges: [CodeSymbolKind: NSImage] = [:]

    init(
        content: JumpBarMenuContent,
        files: [String],
        currentFile: String,
        currentSymbol: CodeSymbol?,
        scheme: ColorScheme,
        onPick: @escaping (JumpBarPick) -> Void
    ) {
        self.files = files
        self.currentFile = currentFile
        self.currentSymbol = currentSymbol
        self.scheme = scheme
        self.onPick = onPick
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        switch content {
        case let .folder(listing):
            addListing(listing, to: menu)
        case let .members(symbols):
            symbols.forEach { menu.addItem(symbolItem($0, depth: 0)) }
        case let .fileSymbols(rows):
            addFilterField()
            for row in rows {
                let item = symbolItem(row.symbol, depth: row.depth)
                symbolItems.append((item, row))
                menu.addItem(item)
            }
        }
    }

    /// Drops the menu below `view`, at least as wide as it.
    func popUp(below view: NSView) {
        menu.minimumWidth = view.bounds.width
        let point = NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 3 : -3)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    // MARK: Filter

    /// Hides the symbol rows whose name does not contain `text`.
    func applyFilter(_ text: String) {
        for (item, row) in symbolItems {
            item.isHidden = !row.matches(text)
        }
    }

    /// The first row the filter leaves, picked by Return.
    var firstVisibleSymbolItem: NSMenuItem? {
        symbolItems.first { !$0.item.isHidden }?.item
    }

    private func addFilterField() {
        let field = NSSearchField(frame: NSRect(x: 10, y: 3, width: 220, height: 22))
        field.placeholderString = "Filter"
        field.sendsWholeSearchString = true
        field.delegate = self
        field.target = self
        field.action = #selector(filterCommitted(_:))
        field.autoresizingMask = [.width]
        field.setAccessibilityLabel("Filter symbols")
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        holder.autoresizingMask = [.width]
        holder.addSubview(field)
        let item = NSMenuItem()
        item.view = holder
        menu.addItem(item)
        menu.addItem(.separator())
        filterField = field
    }

    func controlTextDidChange(_ notification: Notification) {
        applyFilter(filterField?.stringValue ?? "")
    }

    @objc private func filterCommitted(_ sender: NSSearchField) {
        guard let item = firstVisibleSymbolItem else {
            NSSound.beep()
            return
        }
        menu.cancelTracking()
        pick(item)
    }

    // MARK: NSMenuDelegate

    /// The filter takes the keyboard as the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu, let field = filterField else { return }
        RunLoop.main.perform(inModes: [.eventTracking, .default]) {
            field.window?.makeFirstResponder(field)
        }
    }

    /// A folder's submenu is filled the first time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let folder = pendingFolders.removeValue(forKey: ObjectIdentifier(menu)) else { return }
        addListing(JumpBarFolderListing(folder: folder, files: files), to: menu)
    }

    // MARK: Items

    private func addListing(_ listing: JumpBarFolderListing, to menu: NSMenu) {
        for folder in listing.subfolders {
            let item = NSMenuItem(title: (folder as NSString).lastPathComponent, action: nil, keyEquivalent: "")
            item.image = Self.folderImage
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.delegate = self
            pendingFolders[ObjectIdentifier(submenu)] = folder
            item.submenu = submenu
            menu.addItem(item)
        }
        for file in listing.files {
            let item = pickItem((file as NSString).lastPathComponent, pick: .file(file))
            item.image = Self.fileImage(file)
            item.state = file == currentFile ? .on : .off
            item.toolTip = file
            menu.addItem(item)
        }
        if listing.subfolders.isEmpty, listing.files.isEmpty {
            let empty = NSMenuItem(title: "No Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
    }

    private func symbolItem(_ symbol: CodeSymbol, depth: Int) -> NSMenuItem {
        let item = pickItem(symbol.name, pick: .symbol(symbol))
        item.image = badge(symbol.kind)
        item.indentationLevel = min(depth, 15)
        item.state = symbol == currentSymbol ? .on : .off
        item.toolTip = symbol.signature.isEmpty ? nil : symbol.signature
        return item
    }

    private func pickItem(_ title: String, pick: JumpBarPick) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
        item.target = self
        item.tag = picks.count
        picks.append(pick)
        return item
    }

    @objc private func picked(_ sender: NSMenuItem) {
        pick(sender)
    }

    private func pick(_ item: NSMenuItem) {
        guard picks.indices.contains(item.tag) else { return }
        onPick(picks[item.tag])
    }

    private func badge(_ kind: CodeSymbolKind) -> NSImage? {
        if let image = badges[kind] { return image }
        let image = CodeKindBadge.menuImage(kind, size: 15, scheme: scheme)
        badges[kind] = image
        return image
    }

    private static let folderImage = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")

    private static func fileImage(_ path: String) -> NSImage {
        let type = UTType(filenameExtension: (path as NSString).pathExtension) ?? .plainText
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

extension CodeKindBadge {
    /// The badge as a menu item's image.
    static func menuImage(_ kind: CodeSymbolKind, size: CGFloat = 18, scheme: ColorScheme) -> NSImage? {
        let renderer = ImageRenderer(content: CodeKindBadge(kind: kind, size: size).environment(\.colorScheme, scheme))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}

/// The jump bar's half that is not SwiftUI: the file on screen as a
/// `JumpBarModel`, the segments' anchor views, and the menus (also for ⌃6
/// from the Navigate menu, through `CodeNavigationCenter`).
@MainActor
final class JumpBarController: FileSymbolsPresenting {
    struct Snapshot {
        let model: JumpBarModel
        let symbols: [CodeSymbol]
        let files: [String]
    }

    private struct WeakAnchor {
        weak var view: NSView?
    }

    private let files: CodeFilesCenter
    private let project: Workbench
    /// Shows a built menu (`popUp(below:)`; a recorder in tests).
    private let present: @MainActor (JumpBarMenu, NSView) -> Void
    private var anchors: [Int: WeakAnchor] = [:]

    init(files: CodeFilesCenter, project: Workbench, present: @escaping @MainActor (JumpBarMenu, NSView) -> Void = { $0.popUp(below: $1) }) {
        self.files = files
        self.project = project
        self.present = present
    }

    /// The file on screen with the cursor the page last reported in it;
    /// nil with no tab open. Read in the view body: it observes the cursor,
    /// the tabs and the index.
    func snapshot() -> Snapshot? {
        guard let active = files.tabs(for: project).active else { return nil }
        let index = files.codeIndex?.index(for: project.id)
        let cursor = files.cursors[project.id]
        let symbols = index?.symbols(in: active) ?? []
        let model = JumpBarModel(
            path: active, rootName: project.folderURL.lastPathComponent,
            cursorLine: cursor?.path == active ? cursor?.line : nil,
            symbols: symbols, language: index?.definitionLanguage(of: active), state: index?.state ?? .idle
        )
        return Snapshot(model: model, symbols: symbols, files: index?.files ?? [])
    }

    func setAnchor(_ view: NSView, segment: Int) {
        anchors[segment] = WeakAnchor(view: view)
    }

    /// A segment was clicked: its menu below it.
    func showMenu(segment: Int) {
        guard let snapshot = snapshot(), let view = anchors[segment]?.view,
              let content = snapshot.model.menuContent(forSegment: segment, symbols: snapshot.symbols, files: snapshot.files) else {
            NSSound.beep()
            return
        }
        // The segment's own symbol: the one at the cursor for the last.
        let current: CodeSymbol? = if case let .symbol(symbol) = snapshot.model.segments[segment] { symbol } else { nil }
        let scheme: ColorScheme = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        let menu = JumpBarMenu(
            content: content, files: snapshot.files, currentFile: snapshot.model.path, currentSymbol: current, scheme: scheme
        ) { [weak self] pick in
            self?.open(pick)
        }
        present(menu, view)
    }

    /// ⌃6: the last segment's menu, the file's symbols under the filter.
    func presentFileSymbols() -> Bool {
        guard let snapshot = snapshot(), !snapshot.symbols.isEmpty else { return false }
        let last = snapshot.model.segments.count - 1
        guard anchors[last]?.view != nil else { return false }
        showMenu(segment: last)
        return true
    }

    private func open(_ pick: JumpBarPick) {
        let (path, line, col): (String, Int?, Int?) = switch pick {
        case let .file(path): (path, nil, nil)
        case let .symbol(symbol): (symbol.path, symbol.line, symbol.col)
        }
        files.navigation?.openFromJumpBar(path: path, line: line, col: col, project: project)
    }
}
