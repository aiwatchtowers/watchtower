import SwiftUI
import WatchtowerCore

/// The current turn's steps above the live line (#2065 spec §3): a fixed
/// six-row slot from the moment it appears, fewer steps bottom-aligned, the
/// newest next to the line. It follows the newest step unless the owner
/// scrolled up; a new step never changes its height.
struct WorkchatStepsList: View {
    let slot: WorkchatLivePresentation.StepsSlot

    /// The owner sits at the bottom: a new step scrolls into view.
    @State private var pinned = true
    /// The content height of the last measurement: a change is a new step, not a scroll.
    @State private var contentHeight: CGFloat = 0

    private static let bottomID = "workchat-steps-bottom"
    private static let space = "workchat-steps"
    private static let height = WorkchatLivePresentation.stepsHeight(rowHeight: ListLayout.lineMinHeight)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let earlier = slot.earlierLine {
                        Text(earlier).foregroundStyle(.tertiary).frame(height: ListLayout.lineMinHeight)
                    }
                    ForEach(slot.rows) { row in stepRow(row) }
                    Color.clear.frame(height: 0).id(Self.bottomID)
                }
                .frame(minHeight: Self.height, alignment: .bottom)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: StepsFrameKey.self, value: geo.frame(in: .named(Self.space)))
                })
            }
            .coordinateSpace(name: Self.space)
            // No default bottom anchor: on macOS 14 it also applies to growth and would pull a reader who
            // scrolled up back down. The first placement scrolls once; later steps follow `pinned` alone.
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onPreferenceChange(StepsFrameKey.self) { frame in
                // A scroll moves the content; a new step grows it and keeps the last answer.
                if frame.height == contentHeight { pinned = frame.maxY <= Self.height + 1 }
                contentHeight = frame.height
            }
            .onChange(of: slot.rows.map(\.id)) { _, _ in
                if pinned { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
        .frame(height: Self.height)
        // The cut-off top fades once the steps outgrow the slot, so it reads as "scrolls".
        .mask(LinearGradient(stops: [.init(color: slot.rows.count > WorkchatLivePresentation.stepsVisibleRows ? .clear : .black,
                                           location: 0),
                                     .init(color: .black, location: 0.2)],
                             startPoint: .top, endPoint: .bottom))
        .font(.caption)
        // Quiet (#2201 §1): no card, a thin rule under the live line's chevron.
        .padding(.leading, Spacing.medium)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: Stroke.hairline * 2)
        }
        .padding(.leading, Spacing.large + IconSize.header / 2)
        .padding(.trailing, Spacing.large)
        .padding(.bottom, Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(slot.title)
    }

    private func stepRow(_ row: WorkchatLivePresentation.StepRow) -> some View {
        HStack(spacing: Spacing.compact) {
            Group {
                if row.running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: row.symbol)
                }
            }
            .frame(width: IconSize.header)
            Text(row.summary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.summary)
            Spacer(minLength: Spacing.compact)
            if let time = row.time {
                Text(time)
                    .monospacedDigit()
                    .foregroundStyle(row.running ? .secondary : .tertiary)
            }
        }
        .foregroundStyle(row.running ? .primary : .tertiary)
        .frame(height: ListLayout.lineMinHeight)
    }
}

private struct StepsFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
