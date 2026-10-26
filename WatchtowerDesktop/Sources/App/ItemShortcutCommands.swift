import AppKit
import SwiftUI
import WatchtowerCore

/// What the shared View-menu items act on while the Chats tab is in the key
/// window (spec 2026-10-26 §5.4): published by `ChatSplitView` as a scene
/// value, like the Workbench tab's `WorkbenchMenuContext`, so at most one
/// of the two is set for a window.
@MainActor
struct ChatsMenuContext {
    let historyVM: ChatHistoryViewModel
    /// The search sheet or the rename field has the keys.
    var keysTaken = false
    /// The Chats panel is shown: ⌘1…⌘9 and ⌘[ act on it only then (ask
    /// #660).
    var panelVisible = true
    /// Opens a chat as a click on its row does.
    let openChat: (Int64) -> Void

    /// ⌘1…⌘9 (and ⌘[) act on the panel's rows.
    var canUseRowKeys: Bool { !keysTaken && panelVisible }

    var shortcutState: ItemShortcutTarget.Chats {
        .init(canUseRowKeys: canUseRowKeys, projectSelected: historyVM.level != .all)
    }

    /// ⌘n: the panel's n-th row, in the order shown.
    func open(atShortcut n: Int) {
        guard let id = historyVM.rowID(atShortcut: n) else { return }
        openChat(id)
    }
}

private struct ChatsMenuContextKey: FocusedValueKey {
    typealias Value = ChatsMenuContext
}

extension FocusedValues {
    var chatsMenu: ChatsMenuContext? {
        get { self[ChatsMenuContextKey.self] }
        set { self[ChatsMenuContextKey.self] = newValue }
    }
}

extension WorkbenchMenuContext.BackAction {
    var itemShortcutBack: ItemShortcutTarget.Back {
        switch self {
        case .popSubagent: .popSubagent
        case .showAllWorkbenches: .showAllWorkbenches
        }
    }
}

/// View → Back (⌘[) and View → Go to Item ▸ 1…9 (spec 2026-10-26 §4,
/// §5.4): one set of items for the Workbench page and the Chats tab,
/// resolved by `ItemShortcutTarget.resolve`. The only binding of each chord.
/// Inside the Files editor Monaco keeps ⌘[ (the page consumes it before the
/// menu sees it).
struct ItemShortcutCommands: Commands {
    @FocusedValue(\.workbenchMenu) private var workbench
    @FocusedValue(\.sessionChatPop) private var sessionChatPop
    @FocusedValue(\.chatsMenu) private var chats

    private var resolution: ItemShortcutTarget.Resolution {
        ItemShortcutTarget.resolve(
            workbench: workbench.map { context in
                .init(
                    canUseSessionKeys: context.canUseSessionKeys,
                    back: context.backAction(popAvailable: sessionChatPop != nil)?.itemShortcutBack
                )
            },
            chats: chats?.shortcutState
        )
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            let resolution = resolution
            // The focused session chat's open subagent pops first (#711).
            Button("Back") { performBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(resolution.back == nil)
            Menu("Go to Item") {
                ForEach(1...SessionSwitcherPresentation.maxShortcut, id: \.self) { n in
                    Button(resolution.items == .chatRows ? "Chat \(n)" : "Session \(n)") { openItem(n) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                        .disabled(resolution.items == nil)
                }
            }
        }
    }

    /// Re-resolved when the chord fires, and only while the page's window
    /// itself is key (`WorkbenchCommands.pageTakesKeys`).
    private func performBack() {
        guard WorkbenchCommands.pageTakesKeys(NSApp.keyWindow) else { return }
        switch resolution.back {
        case .popSubagent: sessionChatPop?()
        case .showAllWorkbenches: workbench?.vm.showAllWorkbenches()
        case .showAllChats: chats?.historyVM.selectLevel(.all)
        case nil: break
        }
    }

    private func openItem(_ n: Int) {
        guard WorkbenchCommands.pageTakesKeys(NSApp.keyWindow) else { return }
        switch resolution.items {
        case .workbenchSessions:
            if let vm = workbench?.vm { Task { await vm.openSession(atShortcut: n) } }
        case .chatRows: chats?.open(atShortcut: n)
        case nil: break
        }
    }
}
