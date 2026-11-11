package link

import (
	"slices"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/hub/transport"
)

// Go twins of the Swift CloudKit linking tests that had none (go-hub phase
// 3, Task 24): bounded share calls and the public link's one writer (#262).

// gate holds the next call of op until release is closed; arrived is
// closed when the call is held.
func (f *fakeShares) gate(op string) (arrived, release chan struct{}) {
	arrived, release = make(chan struct{}), make(chan struct{})
	f.once(op, func() {
		close(arrived)
		<-release
	})
	return arrived, release
}

// settled checks cond once every goroutine of the test's synctest bubble is
// blocked: the background link writer has run as far as it can.
func settled(t *testing.T, what string, cond func() bool) {
	t.Helper()
	synctest.Wait()
	if !cond() {
		t.Fatalf("never: %s", what)
	}
}

// writerIdle: no public-link write runs.
func (c *Center) writerIdle() bool {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	return c.ck.writer == nil
}

func (c *Center) openNonce() string {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	if c.ck.open == nil {
		return ""
	}
	return c.ck.open.nonce
}

func (c *Center) linkCloseRetry() (time.Time, int) {
	c.ck.mu.Lock()
	defer c.ck.mu.Unlock()
	return c.ck.linkCloseAt, c.ck.linkCloseTries
}

// twin of MobileLinkCenterTests.testAHungParticipantLookupDoesNotHoldTheRelayPass
func TestAHungParticipantLookupDoesNotHoldTheRelayPass(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newCKRig(t)
		r.c.shareTimeout = 100 * time.Millisecond
		code := r.issueCK()
		r.s.join("_colleague-a")
		r.s.hang("participants")
		a := newPhone(t)
		started := time.Now()

		_, _ = r.ckHello(a, code.Nonce, sharedHello("_colleague-a"))

		if d := time.Since(started); d != r.c.shareTimeout { // the bubble's clock: the one bounded lookup
			t.Errorf("held the pass %v, want the share timeout %v", d, r.c.shareTimeout)
		}
		if r.linked(a) || len(pendingIDs(t, r.c)) != 0 || r.codeUsedBy(code.Nonce) != "" {
			t.Error("an unverified phone was linked or waits for the owner")
		}
	})
}

// twin of MobileLinkCenterTests.testAHungCloseAfterALinkDoesNotHoldTheRelayPass (the link half: the runtime
// runs this close in the background, hubRuntime.afterConfirm)
func TestAHungCloseAfterALinkDoesNotHoldTheRelayPass(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newCKRig(t)
		r.c.shareTimeout = 100 * time.Millisecond
		code := r.issueCK()
		r.s.hang("set_public_link")
		a := newPhone(t)
		started := time.Now()

		r.linkCK(a, code.Nonce)
		if !r.linked(a) {
			t.Fatal("not linked")
		}
		if err := r.c.CloseLink(r.ctx, r.s, CloseUsed); err == nil {
			t.Error("the hung close reads as done")
		}
		if d := time.Since(started); d != r.c.shareTimeout { // the bubble's clock: the one bounded close
			t.Errorf("the close took %v, want the share timeout %v", d, r.c.shareTimeout)
		}
		if r.sweepMark() != "1" {
			t.Error("the timed-out close does not stay pending")
		}
	})
}

// twin of MobileLinkCenterTests.testASharedPhonesUnlinkAfterItLeftTheSharesRemovesIt
func TestASharedPhonesUnlinkAfterItLeftTheSharesRemovesIt(t *testing.T) {
	r := newCKRig(t)
	r.s.join("_colleague-a")
	code := r.issueCK()
	a := newPhone(t)
	r.linkCK(a, code.Nonce, sharedHello("_colleague-a"))
	for _, z := range ckZones {
		if err := r.s.RemoveParticipants(r.ctx, z, []string{"_colleague-a"}); err != nil {
			t.Fatal(err)
		}
	}
	unlinked := true
	rec := DeviceRecord{Creator: "_colleague-a", Shares: r.s}
	rec.Payload.DeviceID, rec.Payload.Name, rec.Payload.Scope = a.id.String(), "iPhone", "shared"
	rec.Payload.UserRecordName, rec.Payload.Unlinked = "_colleague-a", &unlinked

	if err := r.c.ApplyDeviceRecord(r.ctx, a.id.String(), rec); err != nil {
		t.Fatalf("a missing participant is no error: %v", err)
	}
	if r.linked(a) {
		t.Fatal("still linked")
	}
	if kb := r.mustKeybox(a); kb.Grant.Revoked == nil || !*kb.Grant.Revoked || kb.Keys != nil {
		t.Errorf("keybox %+v", kb.Grant)
	}
}

// twin of MobileLinkCenterTests.testANewCodeWaitsForTheAccountChangesClose
func TestANewCodeWaitsForTheAccountChangesClose(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newCKRig(t)
		r.issueCK()
		arrived, release := r.s.gate("set_public_link")
		changed := make(chan error, 1)
		go func() { changed <- r.c.AccountChanged(r.ctx, r.s) }()
		<-arrived

		issued := make(chan string, 1)
		go func() {
			p, _, err := r.c.IssueCloudKit(r.ctx, r.s)
			if err != nil {
				t.Errorf("issue: %v", err)
			}
			issued <- p.Nonce
		}()
		close(release)
		nonce := <-issued
		<-changed

		if r.c.openNonce() != nonce || nonce == "" {
			t.Error("the new code is not the one on screen")
		}
		settled(t, "the writer settles", r.c.writerIdle)
		if !r.s.isOpen() {
			t.Error("the account change's close shut the new code's link")
		}
	})
}

// twin of MobileLinkCenterTests+SharedLink.testAGraceSweepFiringMidIssueStandsDown
func TestAGraceSweepFiringMidIssueStandsDown(t *testing.T) {
	r := newCKRig(t)
	r.c = r.ckCenter(Sweep{AnswerGrace: time.Second})
	r.issueCK()
	if err := r.c.CloseLink(r.ctx, r.s, CloseSheetClosed); err != nil {
		t.Fatal(err)
	}
	r.advance(2 * time.Second)
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	arrived, release := r.s.gate("set_public_link")
	issued := make(chan error, 1)
	go func() {
		_, _, err := r.c.IssueCloudKit(r.ctx, r.s)
		issued <- err
	}()
	<-arrived
	relay := transport.SharedMailboxZone(testRelayID)
	r.s.join("_colleague-c", relay)

	// A close lands while the issue opens the link; its grace sweep falls due at once.
	if err := r.c.CloseLink(r.ctx, r.s, CloseSheetClosed); err != nil {
		t.Fatal(err)
	}
	r.advance(2 * time.Second)
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	close(release)
	if err := <-issued; err != nil {
		t.Fatal(err)
	}

	if !r.s.isOpen() {
		t.Error("the new link was closed mid-issue")
	}
	if got := r.s.names(relay); !slices.Equal(got, []string{"_colleague-c"}) {
		t.Errorf("swept mid-issue: %v", got)
	}
	if r.sweepMark() != "1" {
		t.Error("the new code's close no longer sweeps")
	}
}

// twin of MobileLinkCenterTests+SharedLink.testALateLinkCloseNeverLeavesANewCodesLinkShut
func TestALateLinkCloseNeverLeavesANewCodesLinkShut(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newCKRig(t)
		r.c.shareTimeout = 100 * time.Millisecond
		r.issueCK()
		arrived, release := r.s.gate("set_public_link")
		_ = r.c.CloseLink(r.ctx, r.s, CloseSheetClosed) // times out; the close is still on its way
		<-arrived

		code := r.issueCK()
		close(release)

		settled(t, "the new code's link ends open", func() bool { return r.c.writerIdle() && r.s.isOpen() })
		if r.c.openNonce() != code.Nonce {
			t.Error("the new code is not on screen")
		}
	})
}

// twin of MobileLinkCenterTests+SharedLink.testALateLinkOpenAfterTheCloseIsClosedAgain
func TestALateLinkOpenAfterTheCloseIsClosedAgain(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newCKRig(t)
		r.c.shareTimeout = 100 * time.Millisecond
		arrived, release := r.s.gate("set_public_link")
		r.issueCK() // its open times out: a QR without share URLs
		<-arrived
		_ = r.c.CloseLink(r.ctx, r.s, CloseRestart)
		close(release)

		settled(t, "the link ends closed", func() bool { return r.c.writerIdle() })
		if r.s.isOpen() {
			t.Error("the late open left the link open after the close")
		}
		if r.c.openNonce() != "" {
			t.Error("a code is still on screen")
		}
	})
}

// twin of MobileLinkCenterTests+SharedLink.testAFailedReconcilingCloseIsMarkedAndRetried
func TestAFailedReconcilingCloseIsMarkedAndRetried(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newCKRig(t)
		r.c.shareTimeout = 100 * time.Millisecond
		r.issueCK()
		arrived, release := r.s.gate("set_public_link")
		_ = r.c.CloseLink(r.ctx, r.s, CloseSheetClosed)
		<-arrived
		retryAt, tries := r.c.linkCloseRetry()
		if retryAt.IsZero() {
			t.Fatal("the timed-out close schedules no retry")
		}
		// The mark alone must not decide: the writer's failed close sets it again.
		if err := r.st.SetMeta(MetaShareSweepPending, "0"); err != nil {
			t.Fatal(err)
		}
		r.advance(5 * time.Second)
		r.s.setFailing("set_public_link")
		close(release)

		settled(t, "the failed close marks the sweep again", func() bool { return r.c.writerIdle() && r.sweepMark() == "1" })
		if !r.s.isOpen() {
			t.Error("the reconciling close did not fail")
		}
		if at, n := r.c.linkCloseRetry(); !at.Equal(retryAt) || n != tries {
			t.Errorf("the running retry chain was restarted: %v/%d, was %v/%d", at, n, retryAt, tries)
		}
	})
}

// twin of MobileLinkCenterTests+SharedLink.testOnlyOnePublicLinkCallRunsAtATime
func TestOnlyOnePublicLinkCallRunsAtATime(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := newCKRig(t)
		r.c.shareTimeout = 100 * time.Millisecond
		r.issueCK()
		arrived, release := r.s.gate("set_public_link")
		_ = r.c.CloseLink(r.ctx, r.s, CloseSheetClosed)
		<-arrived
		r.issueCK()
		_ = r.c.CloseLink(r.ctx, r.s, CloseSheetClosed)
		r.issueCK()
		close(release)

		settled(t, "the link ends open", func() bool { return r.c.writerIdle() && r.s.isOpen() })
		r.s.mu.Lock()
		most := r.s.maxInLink
		r.s.mu.Unlock()
		if most != 1 {
			t.Errorf("%d public-link calls ran at once", most)
		}
	})
}
