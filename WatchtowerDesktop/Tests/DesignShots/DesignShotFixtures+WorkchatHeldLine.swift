import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// A Workchat line held because the terminal prompt holds text (spec 2026-11-24-workchat-polish §6.3, #2201 T7) on
/// the built bubble: `workchat-polish-real-08-held-idle` and `-09-held-working` beside the mockups' 08 and 09. Clear
/// and send is not built (spec C11), so both show Send together and Cancel.
@MainActor
enum WorkchatHeldLineShotFixtures {
    static let shots: [DesignShot] = [
        shot("08-held-idle", working: false),
        shot("09-held-working", working: true)
    ]

    private static func shot(_ name: String, working: Bool) -> DesignShot {
        DesignShot(name: "workchat-polish-real-\(name)", size: NSSize(width: 720, height: 200)) {
            var line = WorkchatOutgoing(id: UUID(), text: WorkchatPolishCopy.heldLine, sentAt: Date(), state: .queued)
            line.holdReason = .promptHasText
            return AnyView(
                WorkchatOutgoingBubble(
                    line: line, working: working, holdPreview: WorkchatPolishCopy.heldPrompt,
                    onSendTogether: {}, onCancel: {}, onShowTerminal: {}
                )
                .padding(Spacing.large)
                .font(.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .detailBackground()
            )
        }
    }
}
