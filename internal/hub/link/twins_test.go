package link

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
)

// Go twins of the Swift linking tests that had none (go-hub phase 3, Task 24:
// MobileLinkCenterTests, its +LinkData, +Permissions, +StartSessions
// extensions and MobileLinkPairingCodeTests). Each names its Swift test.

// rewriteRecord is a linked private phone's own device record as the
// processor hands it over (no creator: the relay names none).
func (r *rig) rewriteRecord(p phone, edit func(*wire.DevicePayload)) {
	r.t.Helper()
	d := wire.DevicePayload{DeviceID: p.id.String(), Name: "iPhone", Scope: wire.ScopePrivate, StartSessions: true,
		UpdatedAt: wire.Time{Time: r.clock()}}
	if edit != nil {
		edit(&d)
	}
	if err := r.c.ApplyDeviceRecord(context.Background(), p.id.String(), DeviceRecord{Payload: d}); err != nil {
		r.t.Fatalf("ApplyDeviceRecord: %v", err)
	}
}

func (r *rig) device(p phone) (row struct {
	typing, perms, startAllowed, startGranted bool
	decided                                   sql.NullFloat64
}) {
	r.t.Helper()
	err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT typing_allowed, permissions_allowed, start_sessions_allowed, start_sessions_granted, decided_at
			FROM devices WHERE device_id = ?`, p.id.String()).
			Scan(&row.typing, &row.perms, &row.startAllowed, &row.startGranted, &row.decided)
	})
	if err != nil {
		r.t.Fatalf("reading the device: %v", err)
	}
	return row
}

func (r *rig) takePublished() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := r.published
	r.published = nil
	return out
}

func (r *rig) count(query string, args ...any) int {
	r.t.Helper()
	var n int
	if err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(query, args...).Scan(&n)
	}); err != nil {
		r.t.Fatal(err)
	}
	return n
}

// twin of MobileLinkCenterTests.testAUsedCodeRecordedUnderAnotherSpellingIsStillThisDevices
func TestAUsedCodeRecordedUnderAnotherSpellingIsStillThisDevices(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	code := linkCode{nonce: "n", issuedAt: now, exp: now, usedBy: "device-a"}
	if d, _ := decide(code, true, "DEVICE-A", now); d != decisionUsedByThisDevice {
		t.Errorf("same device, other case: %v", d)
	}
	if d, reason := decide(code, true, "DEVICE-B", now); d != decisionRefused || reason != wire.RefusedUsedCode {
		t.Errorf("another device: %v %q", d, reason)
	}
}

// twin of MobileLinkCenterTests.testALinkedPhoneKeepsItsLinkWhenItSendsAnUnknownCodeLater
func TestALinkedPhoneKeepsItsLinkWhenItSendsAnUnknownCodeLater(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	later := r.issue()
	r.advance(601 * time.Second)

	madeUp := b64.EncodeToString(bytes.Repeat([]byte{7}, linkNonceLength))
	if _, err := r.c.HandleHello("relay", a.name(), r.hello(a, madeUp)); !errors.Is(err, ErrHelloDropped) {
		t.Fatalf("made-up code: %v", err)
	}
	if got := r.handle(a, later.Nonce); !got.Unanswered {
		t.Errorf("expired code from the linked phone: %+v", got)
	}
	kb := r.mustKeybox(a)
	if !kb.Grant.Linked || kb.Grant.LinkRefused != nil || kb.Keys == nil {
		t.Errorf("the linked phone lost its link: %+v", kb.Grant)
	}
}

// twin of MobileLinkCenterTests.testRelayRecordsOfTheRemovedPhoneAreDroppedNotEchoed (the link half: its
// rollback marks and held actions of every epoch go with it; with no devices row the processor has no relay
// key for it, pinned by actions' TestLateEchoToARemovedPhoneWritesNothing and TestProj16_AnUnlinkedDeviceTypesNothing).
func TestAnUnlinkForgetsThePhonesRelayMarks(t *testing.T) {
	r := newRig(t)
	a, b := newPhone(t), newPhone(t)
	r.confirmLinked(a)
	r.confirmLinked(b)
	marks(t, r, a, b)

	if err := r.c.Unlink(strings.ToLower(a.id.String())); err != nil {
		t.Fatal(err)
	}
	if n := r.count(`SELECT COUNT(*) FROM relay_seen WHERE sender_id = ?`, a.id.String()); n != 0 {
		t.Errorf("%d relay_seen rows of the removed phone", n)
	}
	if n := r.count(`SELECT COUNT(*) FROM held_actions WHERE device_id = ?`, a.id.String()); n != 0 {
		t.Errorf("%d held actions of the removed phone", n)
	}
	if n := r.count(`SELECT COUNT(*) FROM relay_seen WHERE sender_id = ?`, b.id.String()); n != 2 {
		t.Errorf("the other phone's marks: %d", n)
	}
}

// marks writes, for each phone, relay_seen rows of epochs 1 and 2 and a held action.
func marks(t *testing.T, r *rig, ps ...phone) {
	t.Helper()
	err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		for _, p := range ps {
			for epoch := 1; epoch <= 2; epoch++ {
				if _, err := tx.Exec(`INSERT INTO relay_seen (wire_name, sender_id, epoch, seq, at) VALUES (?, ?, ?, ?, 0)`,
					"rec-"+p.id.String()+string(rune('0'+epoch)), p.id.String(), epoch, 5000+epoch); err != nil {
					return err
				}
			}
			if _, err := tx.Exec(`INSERT INTO held_actions (device_id, action_seq, record_name, envelope, held_at) VALUES (?, 9, 'r', x'00', 0)`,
				p.id.String()); err != nil {
				return err
			}
			if _, err := tx.Exec(`UPDATE devices SET last_applied_action_seq = 5001 WHERE device_id = ?`, p.id.String()); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// twin of MobileLinkCenterTests.testARelinkWithoutRemoveForgetsThePhonesRollbackMarks: a phone re-linked
// through a new code without Remove (a reinstall) restarts its seqs, so its marks and its action order go.
func TestARelinkWithoutUnlinkForgetsThePhonesRollbackMarks(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	marks(t, r, a)

	r.confirmLinked(a) // a new code, the same keys, no Unlink

	if n := r.count(`SELECT COUNT(*) FROM relay_seen WHERE sender_id = ?`, a.id.String()); n != 0 {
		t.Errorf("%d rollback marks survive the re-link", n)
	}
	if n := r.count(`SELECT COUNT(*) FROM held_actions WHERE device_id = ?`, a.id.String()); n != 0 {
		t.Errorf("%d held actions survive the re-link", n)
	}
	if d, _, err := r.st.Device(a.id.String()); err != nil || d.LastAppliedActionSeq != 0 {
		t.Errorf("action order not restarted: %d %v", d.LastAppliedActionSeq, err)
	}
}

// twin of MobileLinkCenterTests.testTwoPhonesNamedIPhoneAreBothListedByLinkDate
func TestTwoPhonesNamedIPhoneAreBothListedByLinkDate(t *testing.T) {
	r := newRig(t)
	a, b := newPhone(t), newPhone(t)
	r.confirmLinked(a)
	r.advance(60 * time.Second)
	r.confirmLinked(b)
	list, err := r.st.Devices()
	if err != nil || len(list) != 2 {
		t.Fatalf("devices %d %v", len(list), err)
	}
	if list[0].Name != "iPhone" || list[1].Name != "iPhone" || list[0].ID != a.id.String() || list[1].ID != b.id.String() {
		t.Errorf("listed %s %q, %s %q", list[0].ID, list[0].Name, list[1].ID, list[1].Name)
	}
	if d := list[1].LinkedAt.Sub(list[0].LinkedAt); d != 60*time.Second {
		t.Errorf("link dates %v apart", d)
	}
}

// twin of MobileLinkCenterTests.testASeventyEmojiNameIsClippedAtAGraphemeBoundary
func TestASeventyEmojiNameIsClippedAtAGraphemeBoundary(t *testing.T) {
	const family = "👩\u200d👩\u200d👧\u200d👦"
	r := newRig(t)
	code := r.issue()
	a := newPhone(t)
	r.handle(a, code.Nonce, func(h *wire.DeviceHello) { h.Device.Name = strings.Repeat(family, 70) })
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	want := strings.Repeat(family, 60)
	if d, _, _ := r.st.Device(a.id.String()); d.Name != want {
		t.Errorf("name of %d bytes, want %d", len(d.Name), len(want))
	}
	if g := r.mustKeybox(a).Grant; g.Name != want {
		t.Errorf("grant name of %d bytes", len(g.Name))
	}
}

// twin of MobileLinkCenterTests.testAPhoneThatUnlinkedGetsTheRefusalOfAnExpiredCodeLater
func TestAPhoneThatUnlinkedGetsTheRefusalOfAnExpiredCodeLater(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	unlinked := true
	r.rewriteRecord(a, func(d *wire.DevicePayload) { d.Unlinked = &unlinked })
	if r.linked(a) {
		t.Fatal("still linked after its own unlink")
	}
	second := r.issue()
	r.advance(601 * time.Second)
	if got := r.handle(a, second.Nonce); got.Refused != wire.RefusedExpiredCode || got.Unanswered {
		t.Fatalf("hello: %+v", got)
	}
	if got := refusal(r.mustKeybox(a)); got != wire.RefusedExpiredCode {
		t.Errorf("keybox refusal %q", got)
	}
}

// twin of MobileLinkCenterTests.testAnUnrelatedRewriteKeepsTheTypingGrant (PROJ-16 supporting)
func TestAnUnrelatedRewriteKeepsTheTypingGrant(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	var revoked []string
	r.c.OnRevoke(func(device string) { revoked = append(revoked, device) })
	if err := r.c.Allow(a.id.String(), GrantTyping, true); err != nil {
		t.Fatal(err)
	}
	r.rewriteRecord(a, func(d *wire.DevicePayload) { d.TypingRequested, d.StartSessions = false, false })
	if row := r.device(a); !row.typing || row.startAllowed {
		t.Errorf("after the start-sessions rewrite: %+v", row)
	}
	if len(revoked) != 0 {
		t.Errorf("revoked %v", revoked)
	}
}

// twin of MobileLinkCenterTests.testAnUnchangedStartSessionsChoiceLeavesTheGrantAlone
func TestAnUnchangedStartSessionsChoiceLeavesTheGrantAlone(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	r.takePublished()
	r.rewriteRecord(a, nil) // start sessions on, as linked
	if row := r.device(a); row.decided.Valid {
		t.Errorf("decided at %v", row.decided.Float64)
	}
	if got := r.takePublished(); len(got) != 0 {
		t.Errorf("published %v", got)
	}
}

// twin of MobileLinkCenterTests.testAnUnlinkedDevicesNonceLessRecordChangesNothing
func TestAnUnlinkedDevicesNonceLessRecordChangesNothing(t *testing.T) {
	r := newRig(t)
	x := newPhone(t)
	unlinked := true
	r.rewriteRecord(x, func(d *wire.DevicePayload) { d.StartSessions = false })
	r.rewriteRecord(x, func(d *wire.DevicePayload) { d.Unlinked = &unlinked })
	if grants, err := r.c.Grants(); err != nil || len(grants) != 0 {
		t.Errorf("grants %v %v", grants, err)
	}
	if r.linked(x) || r.refusalRows() != 0 || r.count(`SELECT COUNT(*) FROM revoked_devices`) != 0 {
		t.Error("a never-linked phone's record changed the link state")
	}
	if got := r.takePublished(); len(got) != 0 {
		t.Errorf("published %v", got)
	}
}

// twin of MobileLinkCenterTests.testTwoRefusalsAtDifferentTimesPublishDifferentPayloads
func TestTwoRefusalsAtDifferentTimesPublishDifferentPayloads(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	a, b := newPhone(t), newPhone(t)
	r.handle(a, code.Nonce)
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	scan := r.hello(b, code.Nonce)
	if _, err := r.c.HandleHello("relay", b.name(), scan); err != nil {
		t.Fatal(err)
	}
	first, _ := wire.Marshal(r.mustKeybox(b))
	r.advance(5 * time.Second)
	if _, err := r.c.HandleHello("relay", b.name(), scan); err != nil {
		t.Fatal(err)
	}
	kb := r.mustKeybox(b)
	second, _ := wire.Marshal(kb)
	if bytes.Equal(first, second) {
		t.Error("the second refusal reads as the first")
	}
	if refusal(kb) != wire.RefusedUsedCode || kb.Grant.DecidedAt == nil || !kb.Grant.DecidedAt.Equal(r.clock()) {
		t.Errorf("second refusal %+v", kb.Grant)
	}
}

// twin of MobileLinkCenterTests+LinkData.testTheGrantSliceOnlyReadsAndThePruneForgetsAnExpiredRefusal
func TestTheGrantSliceOnlyReadsAndThePruneForgetsAnExpiredRefusal(t *testing.T) {
	r := newRig(t)
	old := r.clock().Add(-RefusalLifetime - time.Second)
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return saveRefusal(tx, pendingDevice{deviceID: "REFUSED-OLD", name: "iPhone", scope: wire.ScopePrivate},
			wire.RefusedExpiredCode, old)
	}); err != nil {
		t.Fatal(err)
	}
	if grants, err := r.c.Grants(); err != nil || len(grants) != 0 {
		t.Errorf("an expired refusal is published: %+v %v", grants, err)
	}
	if r.refusalRows() != 1 {
		t.Error("reading the slice wrote")
	}
	if err := r.c.Sweep(); err != nil {
		t.Fatal(err)
	}
	if r.refusalRows() != 0 {
		t.Error("the prune kept the expired refusal")
	}
}

// twin of MobileLinkCenterTests+LinkData.testANewLinkKeepsTheHellosStartSessionsChoice
func TestANewLinkKeepsTheHellosStartSessionsChoice(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	a := newPhone(t)
	r.handle(a, code.Nonce, func(h *wire.DeviceHello) { h.Device.StartSessions = false })
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	if row := r.device(a); row.startAllowed || row.decided.Valid {
		t.Errorf("device %+v", row)
	}
	if g := r.mustKeybox(a).Grant; g.StartSessionsAllowed || g.DecidedAt != nil {
		t.Errorf("grant start_sessions_allowed %v decided %v", g.StartSessionsAllowed, g.DecidedAt)
	}
}

// twin of MobileLinkCenterTests+Permissions.testAnUnrequestedPermissionsGrantSurvivesARewrite (PROJ-21 supporting)
func TestAnUnrequestedPermissionsGrantSurvivesARewrite(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	if err := r.c.Allow(a.id.String(), GrantPermissions, true); err != nil {
		t.Fatal(err)
	}
	r.rewriteRecord(a, func(d *wire.DevicePayload) { d.StartSessions = false })
	if row := r.device(a); !row.perms {
		t.Error("an unrequested permissions grant was revoked by a rewrite")
	}
}

// twin of MobileLinkCenterTests+StartSessions.testStartingSessionsNeedsTheOwnersGrantAndTyping
func TestStartingSessionsNeedsTheOwnersGrantAndTyping(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	id := a.id.String()
	// mayStart is the published grant and the start gate's inputs (handlers/automation.go, session start).
	mayStart := func() (published, gate bool) {
		t.Helper()
		g := r.mustKeybox(a).Grant
		row := r.device(a)
		return g.StartSessionsGranted != nil && *g.StartSessionsGranted, row.startGranted && row.typing && row.startAllowed
	}
	step := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}

	step(r.c.Allow(id, GrantStartSessions, true))
	if !r.device(a).startGranted {
		t.Fatal("the owner's grant not stored")
	}
	if p, g := mayStart(); p || g {
		t.Error("no typing: no starts")
	}
	step(r.c.Allow(id, GrantTyping, true))
	if p, g := mayStart(); !p || !g {
		t.Error("grant and typing: starts")
	}
	step(r.c.Allow(id, GrantTyping, false))
	if p, g := mayStart(); p || g {
		t.Error("typing revoked closes starts")
	}
	step(r.c.Allow(id, GrantTyping, true))
	step(r.c.Allow(id, GrantStartSessions, false))
	if p, g := mayStart(); p || g {
		t.Error("the start grant revoked")
	}
	step(r.c.Allow(id, GrantStartSessions, true))
	r.rewriteRecord(a, func(d *wire.DevicePayload) { d.StartSessions = false })
	if p, g := mayStart(); p || g {
		t.Error("the phone's own opt-out still holds")
	}
	if !r.device(a).startGranted {
		t.Error("the phone cleared the owner's grant")
	}
}

// twin of MobileLinkPairingCodeTests.testGroundKeysDoNotReproduceTheOwnersCodeBecauseTheHubDrawsTheNonceAfterTheHello
// (security: SAS v2). Every input of the code but the hub's confirm nonce is in the QR; the hub draws that
// nonce only after it opened and checked the hello, so keys ground offline against a guessed nonce do not
// show the owner's code on the Mac.
func TestGroundKeysDoNotReproduceTheOwnersCodeBecauseTheHubDrawsTheNonceAfterTheHello(t *testing.T) {
	r := newRig(t)
	var (
		mu    sync.Mutex
		draws int
	)
	r.c.drawConfirm = func(b []byte) error {
		mu.Lock()
		defer mu.Unlock()
		draws++
		for i := range b {
			b[i] = byte(draws)
		}
		return nil
	}
	drawn := func() int {
		mu.Lock()
		defer mu.Unlock()
		return draws
	}
	code := r.issue()
	linkNonce, _ := b64.DecodeString(code.Nonce)
	hubSig, _ := b64.DecodeString(code.HubSig)
	hubKXRaw, _ := b64.DecodeString(code.HubKX)
	hubKX, err := ecdh.X25519().NewPublicKey(hubKXRaw)
	if err != nil {
		t.Fatal(err)
	}
	sas := func(p phone, confirm []byte) string {
		return secure.SAS(r.kr.HubID(), linkNonce, hubSig, hubKX, p.sig.Public().(ed25519.PublicKey), p.kx.PublicKey(), confirm)
	}

	// A hello no kept code opens is dropped before any draw.
	other := b64.EncodeToString(bytes.Repeat([]byte{9}, linkNonceLength))
	owner := newPhone(t)
	if _, err := r.c.HandleHello("relay", owner.name(), r.hello(owner, other)); !errors.Is(err, ErrHelloDropped) {
		t.Fatalf("hello under no kept code: %v", err)
	}
	if drawn() != 0 {
		t.Fatal("a nonce was drawn for a hello that was never accepted")
	}
	ownerCode := r.handle(owner, code.Nonce, func(h *wire.DeviceHello) { h.Device.Name = "Owner iPhone" }).Code
	if drawn() != 1 {
		t.Fatalf("%d draws for one accepted hello", drawn())
	}
	if want := sas(owner, bytes.Repeat([]byte{1}, secure.ConfirmNonceLength)); ownerCode != want {
		t.Fatalf("the owner's code %s does not use the drawn nonce (%s)", ownerCode, want)
	}

	// Offline: the attacker grinds keys against a guessed nonce until they show the owner's code.
	guessed := make([]byte, secure.ConfirmNonceLength)
	_, sig, _ := ed25519.GenerateKey(rand.Reader)
	var attacker *phone
	for range 200_000 {
		candidate := phoneWith(t, sig)
		if sas(candidate, guessed) == ownerCode {
			attacker = &candidate
			break
		}
	}
	if attacker == nil {
		t.Fatal("the grind found no keys for the guessed nonce")
	}

	shown := r.handle(*attacker, code.Nonce, func(h *wire.DeviceHello) { h.Device.Name = "Owner iPhone" }).Code
	if drawn() != 2 {
		t.Fatalf("%d draws: a fresh nonce for the second hello, drawn after it", drawn())
	}
	kb := r.mustKeybox(*attacker)
	confirm, err := b64.DecodeString(*kb.Grant.ConfirmNonce)
	if err != nil || bytes.Equal(confirm, guessed) {
		t.Fatalf("the attacker's keybox nonce %x", confirm)
	}
	if shown != sas(*attacker, confirm) {
		t.Errorf("the Mac's code %s does not use the drawn nonce", shown)
	}
	if shown == ownerCode {
		t.Skip("the drawn nonce collided by chance (1 in 10 000)")
	}
}

// twin of MobileLinkPairingCodeTests.testARefusalForACodeNoLongerKeptStillAnswers: a code pruned while its
// hello was checked has no counter; its phone still hears why, within the total cap.
func TestARefusalForACodeNoLongerKeptStillAnswers(t *testing.T) {
	r := newRig(t)
	refuse := func(i int) bool {
		t.Helper()
		var ok bool
		err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
			var err error
			p := pendingDevice{deviceID: "PHONE-" + strings.Repeat("X", i), name: "iPhone", scope: wire.ScopePrivate}
			ok, err = refuseHello(tx, p, wire.RefusedExpiredCode, "pruned-code", r.clock())
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}
	for i := range MaxLinkRefusals {
		if !refuse(i + 1) {
			t.Fatalf("refusal %d under a pruned code not answered", i+1)
		}
	}
	if refuse(MaxLinkRefusals + 1) {
		t.Error("the total cap does not hold")
	}
	if !refuse(1) {
		t.Error("a known phone is rewritten in place")
	}
}

// twin of MobileLinkPairingCodeTests.testAHellosNameIsSanitisedForDisplay
func TestAHellosNameIsSanitisedForDisplay(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	cases := []struct{ name, want string }{
		{"Owner\u202es\niPhone\u200b\u0007", "Owners iPhone"},
		{strings.Repeat("x", 80), strings.Repeat("x", wire.MaxMacNameLength)},
		{" \n\u202e ", "iPhone"},
	}
	for _, c := range cases {
		p := newPhone(t)
		if got := r.handle(p, code.Nonce, func(h *wire.DeviceHello) { h.Device.Name = c.name }); got.Name != c.want {
			t.Errorf("%q shown as %q, want %q", c.name, got.Name, c.want)
		}
	}
	if got := displayName("Family 👨\u200d👩\u200d👧 phone"); got != "Family 👨\u200d👩\u200d👧 phone" {
		t.Errorf("emoji joiners: %q", got)
	}
}
