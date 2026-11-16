package chatengine

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chatstore"
)

// The CHAT-03 homes of the Mac pool's deleted Swift guards
// (testChat03DecisionNeverExceedsTheBound,
// testChat03RetiringABusySessionNeverLetsTheQueuedFourthOverlap), and the
// warm sessions the Mac asks for (BEHAVIOR CHAT-03 — see
// docs/inventory/chat.md).

// procOf is the fake process of conv (by its --conversation argument).
func procOf(t *testing.T, g *rig, conv int64) []*fakeProc {
	t.Helper()
	var out []*fakeProc
	for _, p := range g.f.all() {
		if i := slices.Index(p.argv, "--conversation"); i >= 0 && p.argv[i+1] == strconv.FormatInt(conv, 10) {
			out = append(out, p)
		}
	}
	return out
}

// TestChat03_RetiringSessionNeverOverlapsTheQueuedFourth: three chats
// answer, a fourth queues; the first one's turn ends and its session is
// told to close but takes its time to exit (it ignores close). The fourth
// starts only once that process exited (SIGTERM after closeGrace), so no
// more than three processes ever live.
func TestChat03_RetiringSessionNeverOverlapsTheQueuedFourth(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, ignoreClose: true})
		c1, c2, c3, c4 := newConversation(t, g.d), newConversation(t, g.d), newConversation(t, g.d), newConversation(t, g.d)
		for _, c := range []int64{c1, c2, c3} {
			g.send(t, c, "busy", nil)
		}
		synctest.Wait()
		g.send(t, c4, "queued", nil)
		synctest.Wait()
		require.Len(t, g.f.all(), 3)

		procOf(t, g, c1)[0].finish()
		synctest.Wait()
		old := procOf(t, g, c1)[0]
		assert.Contains(t, old.log(), "close", "the idle session was told to make room")
		assert.False(t, old.isExited(), "it ignores close and is still exiting")
		assert.Len(t, g.f.all(), 3, "the fourth waits for the exit")

		time.Sleep(closeGrace)
		synctest.Wait()
		assert.True(t, old.isExited())
		require.Len(t, procOf(t, g, c4), 1, "the fourth starts once the slot is free")
		_, maxAlive := g.f.aliveNow()
		assert.Equal(t, MaxLive, maxAlive)
	})
}

// TestChat03_RetireOfBusySessionsNeverCutsOrOverlaps: a config change (the
// claude.ai connector switch) retires every session while three answer and
// a fourth queues. No running turn is cut, the busy sessions are not
// counted as freeing a slot, and the fourth starts only after a retired
// session's process exited.
func TestChat03_RetireOfBusySessionsNeverCutsOrOverlaps(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true, ignoreClose: true})
		c1, c2, c3, c4 := newConversation(t, g.d), newConversation(t, g.d), newConversation(t, g.d), newConversation(t, g.d)
		for _, c := range []int64{c1, c2, c3} {
			g.send(t, c, "busy", nil)
		}
		synctest.Wait()
		g.send(t, c4, "queued", nil)
		synctest.Wait()

		g.r.RetireWarm()
		synctest.Wait()
		for _, c := range []int64{c1, c2, c3} {
			p := procOf(t, g, c)[0]
			assert.NotContains(t, p.log(), "close", "a turn is never cut")
			assert.False(t, p.isExited())
		}
		_, _, waiting, ok := g.r.Live(c4)
		require.True(t, ok)
		assert.True(t, waiting, "the fourth still waits")

		procOf(t, g, c2)[0].finish()
		synctest.Wait()
		old := procOf(t, g, c2)[0]
		assert.Contains(t, old.log(), "close", "the retired session closes after its turn")
		assert.Len(t, g.f.all(), 3, "no overlap while it exits")
		time.Sleep(closeGrace)
		synctest.Wait()
		require.Len(t, procOf(t, g, c4), 1)
		_, maxAlive := g.f.aliveNow()
		assert.Equal(t, MaxLive, maxAlive)
		// The next turn of a retired chat starts a fresh session.
		procOf(t, g, c1)[0].finish()
		synctest.Wait()
		time.Sleep(closeGrace)
		synctest.Wait()
		g.send(t, c1, "again", nil)
		synctest.Wait()
		assert.Len(t, procOf(t, g, c1), 2)
	})
}

// TestChat03_PredecessorAliveHoldsTheReplacement: a routing change recycles
// an idle session; the replacement of the same chat waits for the old
// process to exit (predecessorAlive) even with free slots.
func TestChat03_PredecessorAliveHoldsTheReplacement(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{ignoreClose: true})
		c := newConversation(t, g.d)
		g.send(t, c, "first", nil)
		synctest.Wait()
		g.send(t, c, "pinned", &chatstore.Routing{Provider: "codex"})
		synctest.Wait()
		procs := procOf(t, g, c)
		require.Len(t, procs, 1, "the replacement waits for the old process")
		assert.Contains(t, procs[0].log(), "close")
		time.Sleep(closeGrace)
		synctest.Wait()
		procs = procOf(t, g, c)
		require.Len(t, procs, 2)
		assert.True(t, procs[0].isExited())
		assert.Contains(t, procs[1].argv, "--provider")
		_, maxAlive := g.f.aliveNow()
		assert.Equal(t, 1, maxAlive, "the two processes of the chat never overlapped")
	})
}

// TestChat03_AdmitNeverExceedsTheBound is the pool decision over every
// shape of the pool (the Swift property): 0–3 sessions with a process,
// each busy or idle and retiring or not, then one or two queued turns and
// a warm request. admit never retires a busy session, never lets more than
// MaxLive processes be or be launched, launches a queued turn only into a
// free slot, and leaves one blocked only when no idle session can make room.
func TestChat03_AdmitNeverExceedsTheBound(t *testing.T) {
	e := New(Config{DB: nil})
	for live := 0; live <= MaxLive; live++ {
		for busyMask := 0; busyMask < 1<<live; busyMask++ {
			for retireMask := 0; retireMask < 1<<live; retireMask++ {
				for queued := 1; queued <= 2; queued++ {
					for _, warm := range []bool{false, true} {
						name := fmt.Sprintf("live%d busy%b retire%b queued%d warm%v", live, busyMask, retireMask, queued, warm)
						checkAdmit(t, e, name, live, busyMask, retireMask, queued, warm)
					}
				}
			}
		}
	}
}

func checkAdmit(t *testing.T, e *Engine, name string, live, busyMask, retireMask, queued int, warm bool) {
	t.Helper()
	now := time.Unix(1000, 0)
	e.sessions = nil
	var running, pending []*session
	for i := range live {
		s := &session{r: e, conv: int64(i + 1), phase: phaseLive, kick: make(chan struct{}, 1),
			lastActivity: now.Add(time.Duration(i) * time.Second)}
		if busyMask&(1<<i) != 0 {
			s.turn = &heldTurn{}
		}
		s.retire = retireMask&(1<<i) != 0
		running = append(running, s)
	}
	for i := range queued {
		pending = append(pending, &session{r: e, conv: int64(100 + i), phase: phasePending, turn: &heldTurn{},
			kick: make(chan struct{}, 1)})
	}
	e.sessions = append(append(e.sessions, running...), pending...)
	var w *session
	if warm {
		w = &session{r: e, conv: 200, phase: phasePending, warm: true, kick: make(chan struct{}, 1)}
		e.sessions = append(e.sessions, w)
	}
	busyBefore := map[*session]bool{}
	retiredBefore := map[*session]bool{}
	for _, s := range running {
		busyBefore[s] = s.turn != nil
		retiredBefore[s] = s.retire
	}

	e.admit()

	processes := 0
	for _, s := range e.sessions {
		if s.phase != phasePending {
			processes++
		}
	}
	assert.LessOrEqual(t, processes, MaxLive, name)
	newlyRetired := 0
	idleLeft := 0
	for _, s := range running {
		if busyBefore[s] && !retiredBefore[s] {
			assert.False(t, s.retire, "%s: a busy session is never evicted", name)
		}
		if s.retire && !retiredBefore[s] {
			newlyRetired++
		}
		if !busyBefore[s] && !s.retire {
			idleLeft++
		}
	}
	freeBefore := MaxLive - live
	launched := 0
	for _, s := range pending {
		if s.phase == phaseLaunch {
			launched++
		}
		if s.blocked {
			assert.Zero(t, idleLeft, "%s: blocked although an idle session could make room", name)
		}
	}
	assert.LessOrEqual(t, launched, max(freeBefore, 0), "%s: a queued turn launches only into a free slot", name)
	if warm {
		assert.Zero(t, newlyRetired-min(newlyRetired, queued), "%s: a warm request never evicts", name)
		if w.phase == phaseLaunch {
			assert.Less(t, launched, freeBefore, "%s: a warm session takes only a slot left free", name)
		} else {
			assert.True(t, w.dropped, "%s: a warm session with no free slot is given up", name)
		}
	}
}

// TestChatengine_WarmStartsTheSessionAheadOfTheFirstTurn: the landing's warm
// request spawns the chat's session before any turn; the first turn then
// runs on that very process, and the warm session closes after IdleTTL
// when no turn comes.
func TestChatengine_WarmStartsTheSessionAheadOfTheFirstTurn(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		require.NoError(t, g.r.Warm(context.Background(), c, nil))
		synctest.Wait()
		require.Len(t, g.f.all(), 1, "warm before any turn")
		assert.Empty(t, g.f.all()[0].turnCommands())
		g.send(t, c, "hi", nil)
		synctest.Wait()
		require.Len(t, g.f.all(), 1, "the first turn runs on the warm process")
		assert.Len(t, g.f.all()[0].turnCommands(), 1)

		idle := newConversation(t, g.d)
		require.NoError(t, g.r.Warm(context.Background(), idle, nil))
		synctest.Wait()
		p := procOf(t, g, idle)[0]
		time.Sleep(IdleTTL)
		synctest.Wait()
		assert.True(t, p.isExited(), "a warm session nobody used closes like any idle one")

		require.ErrorIs(t, g.r.Warm(context.Background(), 999_999, nil), chatstore.ErrConversationGone)
	})
}

// TestChatengine_WarmNeverTakesASlotFromATurn: with every slot answering, a
// warm request starts nothing and evicts nothing.
func TestChatengine_WarmNeverTakesASlotFromATurn(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{block: true})
		for range MaxLive {
			g.send(t, newConversation(t, g.d), "busy", nil)
		}
		synctest.Wait()
		require.NoError(t, g.r.Warm(context.Background(), newConversation(t, g.d), nil))
		synctest.Wait()
		assert.Len(t, g.f.all(), MaxLive)
		for _, p := range g.f.all() {
			assert.NotContains(t, p.log(), "close")
		}
	})
}

// TestChatengine_RetireWarmClosesIdleSessions: the connector switch closes
// an idle session at once; the chat's next turn starts a fresh process.
func TestChatengine_RetireWarmClosesIdleSessions(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		c := newConversation(t, g.d)
		g.send(t, c, "one", nil)
		synctest.Wait()
		g.r.RetireWarm()
		synctest.Wait()
		assert.True(t, g.f.all()[0].isExited())
		g.send(t, c, "two", nil)
		synctest.Wait()
		assert.Len(t, g.f.all(), 2)
	})
}

// TestChatengine_DiscardDeletesOnlyAnUntouchedDraft: chat_manage discard
// deletes a chat with no message and closes its warm session; a chat with
// a message stays.
func TestChatengine_DiscardDeletesOnlyAnUntouchedDraft(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		g := newRig(t, fakeOpts{})
		draft := newConversation(t, g.d)
		require.NoError(t, g.r.Warm(context.Background(), draft, nil))
		synctest.Wait()
		require.NoError(t, g.r.Manage(context.Background(), ManageRequest{Conversation: draft, Op: ManageDiscard}))
		synctest.Wait()
		var n int
		require.NoError(t, g.d.QueryRow(`SELECT COUNT(*) FROM chat_conversations WHERE id = ?`, draft).Scan(&n))
		assert.Zero(t, n)
		assert.True(t, g.f.all()[0].isExited(), "its warm session closes")

		used := newConversation(t, g.d)
		g.send(t, used, "hi", nil)
		synctest.Wait()
		require.NoError(t, g.r.Manage(context.Background(), ManageRequest{Conversation: used, Op: ManageDiscard}))
		require.NoError(t, g.d.QueryRow(`SELECT COUNT(*) FROM chat_conversations WHERE id = ?`, used).Scan(&n))
		assert.Equal(t, 1, n, "a chat with a message is no draft")
	})
}
