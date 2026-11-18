import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// The feed's scroll with `ChatFeedContext.follow` set: it follows the newest content (a new row, streamed text, a
/// tool step) while the reader is at the bottom, stops when they scroll up and offers "Jump to latest", lands at the
/// bottom on a switch of conversation and on a turn's start, and on a focused message once it is loaded
/// (`ChatFollowTracker`, `ChatAutoScrollPolicy`).
struct ChatFollowingScroll: View {
    static let jumpLabel = "Jump to latest"
    static let loadingEarlierLabel = "Loading earlier messages…"

    let rows: [ChatFeedLayout.Row]
    let messages: [ChatFeed.Message]
    let context: ChatFeedContext
    let follow: ChatFeedFollow

    /// Mirrors `box.tracker.following`; starts `true` so opening a conversation lands at the bottom.
    @State private var isFollowing = true
    @State private var box = TrackerBox()
    /// The loading row at the top is on screen (`follow.loadsEarlierAtTop`).
    @State private var earlierRowVisible = false
    private static let bottomID = "chat-feed-bottom"
    private static let scrollSpace = "chat-feed-scroll"

    /// A reference box: feeding the tracker a measurement does not invalidate the view.
    final class TrackerBox {
        var tracker = ChatFollowTracker()
    }

    private var state: ChatAutoScrollPolicy.ThreadState {
        .init(conversationID: follow.conversationID, lastMessageID: messages.last?.id,
              scrollTarget: context.focusMessageID, liveMessageID: follow.liveMessageID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    ChatFeedColumn(context: context) {
                        if follow.loadsEarlierAtTop, context.hasEarlier {
                            loadingEarlierRow
                        }
                        ChatFeedRows(rows: rows, messages: messages, context: rowsContext)
                        // The bottom margin: scrolling to it lands at the content's true bottom.
                        Color.clear.frame(height: Spacing.tight).id(Self.bottomID)
                    }
                    // Measured on the whole content: a lazy row off screen may never publish.
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentFrameKey.self, value: geo.frame(in: .named(Self.scrollSpace)))
                        }
                    )
                }
                .coordinateSpace(name: Self.scrollSpace)
                .defaultScrollAnchor(follow.anchorsBottom ? .bottom : nil)
                .onPreferenceChange(ContentFrameKey.self) { frame in
                    guard let frame else { return }
                    measure(.init(contentTop: frame.minY, contentHeight: frame.height,
                                  viewportHeight: viewport.size.height), proxy: proxy)
                }
                // A height-only resize leaves the content frame unchanged in the scroll space.
                .onChange(of: viewport.size.height) { _, height in
                    guard let last = box.tracker.lastMetrics else { return }
                    measure(.init(contentTop: last.contentTop, contentHeight: last.contentHeight, viewportHeight: height),
                            proxy: proxy)
                }
                .overlay(alignment: .bottom) { jumpButton(proxy: proxy) }
                // One handler for switch, focus, turn start and new row, whatever order separate ones would fire in.
                .onChange(of: state, initial: true) { old, new in
                    let change = old == new
                        ? ChatAutoScrollPolicy.mountChange(new)
                        : ChatAutoScrollPolicy.threadChange(from: old, to: new)
                    handle(change, proxy: proxy)
                }
            }
        }
    }

    /// With the loading row the rows draw no "Load earlier" button of their own.
    private var rowsContext: ChatFeedContext {
        var rows = context
        if follow.loadsEarlierAtTop { rows.hasEarlier = false }
        return rows
    }

    /// Loads earlier messages when it comes on screen while the reader reads older text (a following view keeps the
    /// newest content; the row can lay out at open).
    private var loadingEarlierRow: some View {
        HStack(spacing: Spacing.compact) {
            ProgressView().controlSize(.mini)
            Text(Self.loadingEarlierLabel)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .onAppear {
            earlierRowVisible = true
            if !isFollowing || isShort(box.tracker.lastMetrics) { context.rowActions.loadEarlier() }
        }
        .onDisappear { earlierRowVisible = false }
    }

    /// Content shorter than the viewport keeps the loading row on screen, so it never appears again: load from here.
    private func isShort(_ metrics: ChatAutoScrollPolicy.Metrics?) -> Bool {
        guard let metrics, metrics.viewportHeight > 0 else { return false }
        return metrics.contentHeight < metrics.viewportHeight
    }

    private func handle(_ change: ChatAutoScrollPolicy.ThreadChange, proxy: ScrollViewProxy) {
        switch change {
        case let .jumpToMessage(target):
            box.tracker.restartTracking(following: false)
            sync()
            proxy.scrollTo(ChatFeedLayout.rowID(target), anchor: follow.loadsEarlierAtTop ? .top : .center)
            follow.onFocusApplied?()
        case .switchedConversation:
            box.tracker.restartTracking(following: true)
            sync()
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        case .turnStarted:
            box.tracker.repinToLatest()
            sync()
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        case .newLastRow:
            if isFollowing { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        case .none:
            break
        }
    }

    /// Feeds one measurement to the tracker and pulls a following view down when the content grew under it.
    private func measure(_ current: ChatAutoScrollPolicy.Metrics, proxy: ScrollViewProxy) {
        guard current.viewportHeight > 0 else { return }
        let wasFollowing = box.tracker.following
        let pull = box.tracker.observeMeasurement(current)
        sync()
        if pull { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        guard follow.loadsEarlierAtTop, context.hasEarlier else { return }
        // The loading row appeared before this scroll registered, or the content is still short.
        if (wasFollowing && !box.tracker.following && earlierRowVisible) || isShort(current) {
            context.rowActions.loadEarlier()
        }
    }

    private func sync() {
        guard box.tracker.following != isFollowing else { return }
        isFollowing = box.tracker.following
        follow.onFollowingChange?(isFollowing)
    }

    /// Shown once the reader has scrolled away from the bottom; jumping follows again.
    @ViewBuilder
    private func jumpButton(proxy: ScrollViewProxy) -> some View {
        if !isFollowing {
            Button {
                box.tracker.repinToLatest()
                sync()
                withAnimation(Motion.panel) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            } label: {
                Label(Self.jumpLabel, systemImage: "arrow.down")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.regular)
                    .padding(.vertical, Spacing.tight)
                    .background(Color.accentColor, in: Capsule())
                    .shadow(color: FloatingShadow.color, radius: FloatingShadow.radius, y: FloatingShadow.y)
            }
            .buttonStyle(.plain)
            .padding(.bottom, Spacing.cozy)
        }
    }

    private struct ContentFrameKey: PreferenceKey {
        static let defaultValue: CGRect? = nil
        static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
            value = value ?? nextValue()
        }
    }
}
