import SwiftUI

/// How much space the main window keeps free along the edge the recorder
/// pills (`RecordingIndicatorView`) sit on, so they never cover content.
/// Zero while no pill is visible. The root view measures the indicator
/// stack and pads its whole content by this much on the pills' edge (#397):
/// every screen is cleared at once, with nothing to opt into.
enum RecordingIndicatorInset {
    /// The indicator stack's outer padding — the gap between its pills and
    /// the window's edge.
    static let outerPadding: CGFloat = 16
    /// Spacing between pills in the stack.
    static let stackSpacing: CGFloat = 10

    /// `stackHeight` is the measured height of the pill stack without its
    /// outer padding; an empty stack (nothing recording, queued or failed)
    /// measures zero and reserves nothing. While the live-transcript panel is
    /// expanded, the panel itself reserves nothing: it is a transient overlay
    /// the owner opened that may cover content, and the recorder pills sit
    /// beyond it, so reserving them would pad a gap that clears nothing. Only
    /// what is drawn between the panel and the window's edge
    /// (`belowPanelHeight`: the model-download capsules) still reserves its
    /// own height.
    static func reservedHeight(
        stackHeight: CGFloat,
        expandedPanelShown: Bool = false,
        belowPanelHeight: CGFloat = 0
    ) -> CGFloat {
        let covered = expandedPanelShown ? belowPanelHeight : stackHeight
        return covered > 0 ? covered + outerPadding : 0
    }

    /// The whole stack's extent from the window's edge, the expanded panel
    /// included — what a neighbour in the same corner must stay clear of.
    static func occupiedHeight(stackHeight: CGFloat) -> CGFloat {
        stackHeight > 0 ? stackHeight + outerPadding : 0
    }
}

/// What the indicator reports to its host (`RecordingIndicatorHost`) after
/// every layout change.
struct RecordingIndicatorLayout: Equatable {
    /// Space the content keeps free on the corner's edge.
    var reservedInset: CGFloat
    /// The stack's full extent from the edge (`occupiedHeight`).
    var occupiedHeight: CGFloat

    static let empty = Self(reservedInset: 0, occupiedHeight: 0)
}

/// The window corner the recorder pills sit in (#397). The owner drags the
/// stack and it snaps to the corner nearest the release point; the choice
/// is kept across launches under `storageKey`.
enum RecordingIndicatorCorner: String, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    static let storageKey = "recordingIndicator.corner"
    static let `default`: Self = .bottomTrailing
    /// The root view's coordinate space, the one drag locations are read in.
    static let coordinateSpace = "recordingIndicator.window"

    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var isLeading: Bool { self == .topLeading || self == .bottomLeading }

    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    var horizontalAlignment: HorizontalAlignment { isLeading ? .leading : .trailing }

    /// The content edge that reserves the pills' height.
    var insetEdge: Edge.Set { isTop ? .top : .bottom }

    /// The stack's parts, top to bottom: from the window's interior to its
    /// edge in a bottom corner, mirrored in a top one. The download pills
    /// stay between the recorder pills and the edge (what `reservedHeight`
    /// counts), and the live panel opens toward the interior.
    enum StackPart: CaseIterable { case interrupted, jobs, recording, downloads }

    var stackParts: [StackPart] {
        let interiorToEdge: [StackPart] = [.interrupted, .jobs, .recording, .downloads]
        return isTop ? interiorToEdge.reversed() : interiorToEdge
    }

    /// The capsule's chevron points where the live panel opens — toward the
    /// interior — and the panel's points back to the edge.
    var expandChevron: String { isTop ? "chevron.down" : "chevron.up" }
    var collapseChevron: String { isTop ? "chevron.up" : "chevron.down" }

    /// How far the extract pill (always bottom-trailing) moves up: above the
    /// whole stack, expanded panel included, when they share the corner.
    func extractPillLift(occupiedHeight: CGFloat) -> CGFloat {
        self == .bottomTrailing ? occupiedHeight : 0
    }

    /// How far the meeting banner (always top-centre) moves down: below the
    /// whole stack, expanded panel included, when it sits in a top corner.
    func bannerDrop(occupiedHeight: CGFloat) -> CGFloat {
        isTop ? occupiedHeight : 0
    }

    /// The corner a drag released at `point` leaves the stack in; with no
    /// measured window yet, the stack stays where it was.
    func snapped(releasedAt point: CGPoint, in size: CGSize) -> Self {
        guard size.width > 0, size.height > 0 else { return self }
        return Self.nearest(to: point, in: size)
    }

    /// The corner of the quadrant `point` falls in. The midlines go to the
    /// trailing and bottom sides, so the exact centre is the default corner,
    /// and a point past the window's edge snaps to the corner on that side.
    static func nearest(to point: CGPoint, in size: CGSize) -> Self {
        let trailing = point.x >= size.width / 2
        let bottom = point.y >= size.height / 2
        switch (bottom, trailing) {
        case (false, false): return .topLeading
        case (false, true): return .topTrailing
        case (true, false): return .bottomLeading
        case (true, true): return .bottomTrailing
        }
    }
}
