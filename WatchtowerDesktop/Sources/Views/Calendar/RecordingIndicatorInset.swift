import SwiftUI

/// Spacing of the recorder pills (`RecordingIndicatorView`). The pills
/// float over the window's content and reserve nothing: the owner drags
/// them out of the way instead.
enum RecordingIndicatorInset {
    /// The indicator stack's outer padding — the gap between its pills and
    /// the window's edge when docked in a corner.
    static let outerPadding: CGFloat = 16
    /// Spacing between pills in the stack.
    static let stackSpacing: CGFloat = 10

    /// The whole stack's extent from the window's edge, the expanded panel
    /// included — what a neighbour in the same corner must stay clear of.
    static func occupiedHeight(stackHeight: CGFloat) -> CGFloat {
        stackHeight > 0 ? stackHeight + outerPadding : 0
    }
}

/// Where the stack sits: a corner it is anchored to, plus the owner's
/// offset from that corner's docked spot. Both are kept across launches;
/// the offset is clamped into the window whenever it is drawn, so a
/// smaller window or a taller stack never pushes a pill out of sight.
struct RecordingIndicatorPlacement: Equatable {
    static let offsetXKey = "recordingIndicator.offsetX"
    static let offsetYKey = "recordingIndicator.offsetY"
    /// A release this close to the corner's docked spot, per axis, docks on
    /// that axis.
    static let dockDistance: CGFloat = 24

    var corner: RecordingIndicatorCorner
    var offset: CGSize

    /// Docked in its corner: only then do the neighbours sharing the edge
    /// (`extractPillLift`, `bannerDrop`) step aside — a stack the owner
    /// moved elsewhere pushes nothing.
    var isDocked: Bool { offset == .zero }

    /// The offset kept inside `window` for a stack of `stack` size: the
    /// stack moves only toward the window's interior from its corner, and
    /// no farther than the opposite edge's padding. An unmeasured window
    /// leaves the offset as it is.
    func clampedOffset(stack: CGSize, window: CGSize) -> CGSize {
        guard window.width > 0, window.height > 0 else { return offset }
        let pad = RecordingIndicatorInset.outerPadding
        let roomX = max(0, window.width - stack.width - 2 * pad)
        let roomY = max(0, window.height - stack.height - 2 * pad)
        let x = corner.isLeading ? min(max(offset.width, 0), roomX) : max(min(offset.width, 0), -roomX)
        let y = corner.isTop ? min(max(offset.height, 0), roomY) : max(min(offset.height, 0), -roomY)
        return CGSize(width: x, height: y)
    }

    /// The placement a drag of `translation` leaves the stack in: anchored
    /// to the corner of the quadrant its centre lands in (so the stack's
    /// order and the live panel still open toward the interior), at the
    /// spot it was dropped, clamped into the window and docked on each axis
    /// that ends within `dockDistance` of the corner's spot. An unmeasured
    /// window keeps the placement.
    func released(translation: CGSize, stack: CGSize, window: CGSize) -> Self {
        guard window.width > 0, window.height > 0 else { return self }
        let start = clampedOffset(stack: stack, window: window)
        let origin = Self.dockedOrigin(corner: corner, stack: stack, window: window)
        let dropped = CGPoint(x: origin.x + start.width + translation.width,
                              y: origin.y + start.height + translation.height)
        let centre = CGPoint(x: dropped.x + stack.width / 2, y: dropped.y + stack.height / 2)
        let newCorner = RecordingIndicatorCorner.nearest(to: centre, in: window)
        let newOrigin = Self.dockedOrigin(corner: newCorner, stack: stack, window: window)
        var placed = Self(corner: newCorner,
                          offset: CGSize(width: dropped.x - newOrigin.x, height: dropped.y - newOrigin.y))
        placed.offset = placed.clampedOffset(stack: stack, window: window)
        if abs(placed.offset.width) < Self.dockDistance { placed.offset.width = 0 }
        if abs(placed.offset.height) < Self.dockDistance { placed.offset.height = 0 }
        return placed
    }

    /// The stack's top-left corner when docked in `corner`.
    static func dockedOrigin(corner: RecordingIndicatorCorner, stack: CGSize, window: CGSize) -> CGPoint {
        let pad = RecordingIndicatorInset.outerPadding
        return CGPoint(x: corner.isLeading ? pad : window.width - pad - stack.width,
                       y: corner.isTop ? pad : window.height - pad - stack.height)
    }
}

/// The window corner the recorder pills are anchored to (#397): the one of
/// the quadrant the owner drops the stack in
/// (`RecordingIndicatorPlacement.released`), kept across launches under
/// `storageKey`.
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

    /// The stack's parts, top to bottom: from the window's interior to its
    /// edge in a bottom corner, mirrored in a top one. The download pills
    /// stay between the recorder pills and the edge, and the live panel
    /// opens toward the interior.
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
