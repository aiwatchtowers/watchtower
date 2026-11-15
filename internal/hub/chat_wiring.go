package hub

import (
	"cmp"
	"context"
	"fmt"
	"log"
	"path/filepath"
	"slices"
	"time"

	"watchtower/internal/chatstore"
	"watchtower/internal/hub/actions/handlers"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy"
)

// The AI chat from the phone, the hub's side (iPhone chat spec §4.5–§4.8):
// the runner (chatrun) behind the chat_* handlers, the chat sources fed by
// the handlers' requests, the relay-only capability and the timer that
// republishes what only time changes.

// chatKinds are the chat slice kinds.
var chatKinds = []hubslices.Kind{hubslices.KindChatList, hubslices.KindChatFeed, hubslices.KindChatPage, hubslices.KindChatSearch}

// chatTickEvery is how often the chat timer looks at what time alone
// changes (a watch or request ending, a lease going stale, a grant or the
// capability changing in the sidecar): every slice it changes is
// republished within this.
const chatTickEvery = 5 * time.Second

// chatTitleBudget bounds one AI title (the light-tier call).
const chatTitleBudget = 2 * time.Minute

// chatRequests is the handlers' ChatRequests over the sources' register:
// each request counts from when the phone asked (sources' lengths).
type chatRequests struct{ w *sources.ChatWatches }

func (c chatRequests) WatchFeed(conv int64, purpose string, at time.Time) {
	length := sources.ChatOpenWatch
	if purpose == sources.ChatPurposePrefetch {
		length = sources.ChatPrefetchHold
	}
	c.w.Watch(conv, purpose, at.Add(length))
}

func (c chatRequests) RequestPage(conv, before int64, at time.Time) {
	c.w.Pages.Request(sources.ChatPageKey{Conversation: conv, Before: before}, at.Add(sources.ChatRequestHold))
}

func (c chatRequests) RequestSearch(query string, at time.Time) {
	c.w.Searches.Request(query, at.Add(sources.ChatRequestHold))
}

// chatFilesDir is <workspace>/chat_files: the folder beside the database
// file (ChatAttachmentStore.defaultRootDir); "" without a file.
func chatFilesDir(dbPath string) string {
	if dbPath == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(dbPath), chatstore.FilesDirName)
}

// onRelay says whether the hub runs on the hosted relay now: the switcher's
// active transport on a desktop host, the transport itself elsewhere.
func (h *hubRuntime) onRelay() bool {
	if h.sw != nil {
		return h.sw.IsActive(transport.KindRelay)
	}
	return h.tr != nil && h.tr.Kind() == transport.KindRelay
}

// chatAvailable is the chat capability (spec §4.8): on only on the relay,
// with the chat runner, and with no running Desktop app that ignores the
// chat lease (D18); the organization's workbench_only policy has no chat.
func (h *hubRuntime) chatAvailable() (bool, string) {
	switch {
	case h.mode == policy.MobileWorkbenchOnly:
		return false, wire.ChatOffPolicy
	case h.wiring == nil || h.wiring.set == nil || h.wiring.set.ChatWatches == nil || h.wiring.chat == nil:
		return false, wire.ChatOffRunnerDown
	case !h.onRelay():
		return false, wire.ChatOffNotRelay
	}
	old, err := h.st.OldDesktopRuns(h.sup.o.Clock())
	if err != nil {
		log.Printf("hub: the Desktop heartbeat is unreadable (%s): chat off", errClass(err))
		return false, wire.ChatOffDesktopTooOld
	}
	if old {
		return false, wire.ChatOffDesktopTooOld
	}
	return true, ""
}

// chatDeps is the handlers' chat side (nil under workbench_only, where the
// sources have no chat).
func (h *hubRuntime) chatDeps(o Options, w *wiring, path string) *handlers.ChatDeps {
	if w.set.ChatWatches == nil {
		return nil
	}
	c := &handlers.ChatDeps{
		Available: h.chatAvailable,
		Requests:  chatRequests{w.set.ChatWatches},
		Tools:     o.ChatTools,
		FilesDir:  chatFilesDir(path),
		Store:     w.chatStore,
		Spawn:     w.spawn,
	}
	if w.chat != nil {
		c.Runner = w.chat
	}
	return c
}

// chatTimer republishes the chat slices when something only time changes
// moved (no watchtower.db row changes for it, so the data_version watch
// never sees it): a feed watch, page or search ending; a lease going stale
// (an "answering" chat turning back to read); a phone's chat grant toggled
// in the sidecar. And the heartbeat when the chat capability changed (a
// Desktop heartbeat aging past 2 minutes, the transport switching).
type chatTimer struct {
	watches   *sources.ChatWatches
	fresh     func(nowMS int64) ([]int64, error)
	grant     func() (bool, error)
	available func() (bool, string)
	now       func() time.Time
	publish   func(kinds ...hubslices.Kind)

	primed                bool
	lastChat, lastCap     string
	lastLeases, lastGrant string
}

// check compares what time-only changes leave now with the last check and
// publishes what moved; the first check only records. A failed read is no
// change.
func (c *chatTimer) check() {
	now := c.now()
	pages := c.watches.Pages.Active(now)
	slices.SortFunc(pages, func(x, y sources.ChatPageKey) int {
		return cmp.Or(cmp.Compare(x.Conversation, y.Conversation), cmp.Compare(x.Before, y.Before))
	})
	searches := c.watches.Searches.Active(now)
	slices.Sort(searches)
	if fresh, err := c.fresh(now.UnixMilli()); err == nil {
		c.lastLeases = fmt.Sprint(fresh)
	}
	if g, err := c.grant(); err == nil {
		c.lastGrant = fmt.Sprint(g)
	}
	chat := fmt.Sprintf("%v\x00%v\x00%q\x00%s\x00%s", c.watches.ActiveFeeds(now), pages, searches, c.lastLeases, c.lastGrant)
	on, reason := c.available()
	capSig := fmt.Sprint(on, reason)
	if c.primed {
		if chat != c.lastChat {
			c.publish(chatKinds...)
		}
		if capSig != c.lastCap {
			c.publish(hubslices.KindHeartbeat)
		}
	}
	c.primed, c.lastChat, c.lastCap = true, chat, capSig
}

// run checks every chatTickEvery until ctx ends.
func (c *chatTimer) run(ctx context.Context) {
	t := time.NewTicker(chatTickEvery)
	defer t.Stop()
	c.check()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			c.check()
		}
	}
}
