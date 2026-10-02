import SwiftUI
import WatchtowerCore

/// How roomy a chat is: the main chat and tab-sized embedded chats use
/// `.regular`; docks, the setup side panel and collapsible sections `.compact`.
enum ChatDensity {
    case regular
    case compact

    var rowSpacing: CGFloat { self == .regular ? 16 : 10 }
    var horizontalPadding: CGFloat { self == .regular ? 20 : 12 }
    var topPadding: CGFloat { self == .regular ? 16 : 8 }
    /// The thread column; a compact chat uses its whole (narrow) width.
    var maxColumnWidth: CGFloat { self == .regular ? 760 : .infinity }
    /// The composer's growth limit for a chat that has no window-relative one.
    var composerMaxHeight: CGFloat { self == .regular ? 200 : 120 }
}

/// Frame of the feed content in the feed scroll view's named coordinate
/// space; nil when nothing has published one yet.
private struct ChatContentFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// Reference box for the follow tracker — feeding it a measurement does not
/// invalidate the view, unlike a plain `@State` (the `NowLineFrameBox`
/// precedent); `isFollowing` mirrors the one bit the view renders.
private final class ChatFollowTrackerBox {
    var tracker = ChatFollowTracker()
}

/// The scrolling message column every chat shares (main chat and embedded
/// chats): follows the latest content while the owner is at the bottom,
/// stops when they scroll up, offers "Jump to latest", and lands on a ⌘K hit
/// (`ChatFollowTracker`, `ChatAutoScrollPolicy`). Knows nothing about view
/// models — the rows come from `content`.
struct ChatFeedView<Content: View>: View {
    let state: ChatAutoScrollPolicy.ThreadState
    let lastRowID: Int64?
    var density: ChatDensity = .regular
    var onScrollTargetConsumed: () -> Void = {}
    @ViewBuilder let content: () -> Content

    /// Whether the view tracks the latest content — every content growth
    /// (streamed text, a tool step, an artifact block, a new row) pulls a
    /// following view down; a user scroll up stops it (`ChatFollowTracker`).
    /// Starts `true` so opening a conversation lands at the bottom. Mirrors
    /// `follow.tracker.following`.
    @State private var isFollowing = true
    @State private var follow = ChatFollowTrackerBox()
    private static var bottomSentinelID: String { "chat-bottom-sentinel" }
    private static var scrollSpace: String { "chat-thread-scroll" }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: density.rowSpacing) {
                        content()
                        bottomSentinel
                    }
                    // No bottom padding: the sentinel's own height is it, so
                    // scrolling to the sentinel lands at the content's true
                    // bottom and the measured distance settles at 0.
                    .padding(.top, density.topPadding)
                    .padding(.horizontal, density.horizontalPadding)
                    .frame(maxWidth: density.maxColumnWidth)
                    .frame(maxWidth: .infinity)
                    // Measured on the whole content, not a trailing sentinel:
                    // the content frame is always laid out, while a
                    // `LazyVStack` row off the visible range may never publish.
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ChatContentFramePreferenceKey.self,
                                value: geo.frame(in: .named(Self.scrollSpace))
                            )
                        }
                    )
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(ChatContentFramePreferenceKey.self) { frame in
                    guard let frame else { return }
                    updateFollowState(.init(contentTop: frame.minY, contentHeight: frame.height,
                                            viewportHeight: viewport.size.height), proxy: proxy)
                }
                // The decision depends on both inputs — a height-only resize
                // keeps the content frame byte-identical in the scroll space,
                // so the preference alone would go stale (the
                // `CalendarEventsView` now-line precedent).
                .onChange(of: viewport.size.height) { _, height in
                    guard let last = follow.tracker.lastMetrics else { return }
                    updateFollowState(.init(contentTop: last.contentTop, contentHeight: last.contentHeight,
                                            viewportHeight: height), proxy: proxy)
                }
                .overlay(alignment: .bottom) { jumpToLatestButton(proxy: proxy) }
                // One handler for switch/jump/turn start/new row, so a ⌘K hit
                // that also switches into a streaming conversation lands on
                // the hit whatever order separate handlers would have fired in.
                // `initial`: the view can mount together with a ⌘K hit (opened
                // from a project page); the initial call passes old == new.
                .onChange(of: state, initial: true) { old, new in
                    let change = old == new
                        ? ChatAutoScrollPolicy.mountChange(new)
                        : ChatAutoScrollPolicy.threadChange(from: old, to: new)
                    handleThreadChange(change, proxy: proxy)
                }
            }
        }
    }

    /// Scroll target for "the very bottom" (and the feed's bottom margin);
    /// carries no measurement.
    private var bottomSentinel: some View {
        Color.clear
            .frame(height: density.topPadding)
            .id(Self.bottomSentinelID)
    }

    private func handleThreadChange(_ change: ChatAutoScrollPolicy.ThreadChange, proxy: ScrollViewProxy) {
        switch change {
        case let .jumpToMessage(target):
            follow.tracker.restartTracking(following: false)
            syncFollowing()
            proxy.scrollTo(target, anchor: .center)
            onScrollTargetConsumed()
        case .switchedConversation:
            follow.tracker.restartTracking(following: true)
            syncFollowing()
            if let lastRowID { proxy.scrollTo(lastRowID, anchor: .bottom) }
        case .turnStarted:
            follow.tracker.repinToLatest()
            syncFollowing()
            proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)
        case .newLastRow:
            if isFollowing, let lastRowID { proxy.scrollTo(lastRowID, anchor: .bottom) }
        case .none:
            break
        }
    }

    /// Feeds one content measurement to the tracker and pulls a following
    /// view down when the content grew under it.
    private func updateFollowState(_ current: ChatAutoScrollPolicy.Metrics, proxy: ScrollViewProxy) {
        guard current.viewportHeight > 0 else { return }
        let pull = follow.tracker.observeMeasurement(current)
        syncFollowing()
        if pull { proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom) }
    }

    private func syncFollowing() {
        if follow.tracker.following != isFollowing { isFollowing = follow.tracker.following }
    }

    /// Shown only once the user has scrolled away from the bottom; jumping
    /// re-enables following so the next delta resumes tracking it.
    @ViewBuilder
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        if !isFollowing {
            Button {
                follow.tracker.repinToLatest()
                syncFollowing()
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)
                }
            } label: {
                Label("Jump to latest", systemImage: "arrow.down")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .padding(.bottom, 12)
        }
    }
}
