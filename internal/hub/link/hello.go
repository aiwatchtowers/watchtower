package link

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"
	"unicode"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
)

// Pending is what a hello led to. A waiting request has Code (the four-digit
// code both screens show); a refused hello has Refused (a wire.Refused*
// value) and Unanswered when no refusal keybox is written (the caps are
// reached, or the phone is linked already and keeps its link). Neither is set
// when the hello changes nothing (the linked phone re-sent the code it used).
type Pending struct {
	DeviceID   string
	Name       string
	Code       string
	ReceivedAt time.Time
	Refused    string
	Unanswered bool
}

// openedHello is a hello opened and checked.
type openedHello struct {
	hello     wire.DeviceHello
	device    string
	code      linkCode
	linkNonce []byte
	sigPub    ed25519.PublicKey
	kxPub     *ecdh.PublicKey
}

// HandleHello decides one phone hello (spec §2.3, F4): it opens it under each
// kept code's nonce, newest first, checks its signature and that its device
// id is its signing key's hash (D7), then decides the code without
// consuming it. A refused code is answered with a refusal keybox sealed to
// the hello's key (F5), within MaxRefusalsPerCode and MaxLinkRefusals; a valid
// one waits for the owner with a fresh confirm nonce (SAS v2: drawn only after
// the hello was accepted). Each code draws at most MaxNoncesPerCode nonces,
// a re-sent unchanged hello draws none. ErrHelloDropped when the hello is
// left unanswered (no kept code opens it, or a check fails).
func (c *Center) HandleHello(zone, wireName string, env []byte) (Pending, error) {
	c.mu.Lock()
	defer c.unlock()
	opened, err := c.openHello(zone, wireName, env)
	if err != nil {
		return Pending{}, err
	}
	payload := opened.hello.Device
	now := c.now()
	out := Pending{DeviceID: opened.device, Name: displayName(payload.Name), ReceivedAt: now}
	confirm := make([]byte, secure.ConfirmNonceLength)
	if _, err := rand.Read(confirm); err != nil {
		return Pending{}, fmt.Errorf("link: random: %w", err)
	}
	defer clear(confirm)
	sas := secure.SAS(c.keys.HubID(), opened.linkNonce, c.keys.Signer().Public().(ed25519.PublicKey),
		c.keys.Agreement().PublicKey(), opened.sigPub, opened.kxPub, confirm)
	request := pendingDevice{
		deviceID: opened.device, name: out.Name, model: payload.Model, scope: payload.Scope,
		signingKey: opened.sigPub, agreementKey: opened.kxPub.Bytes(), linkNonce: opened.code.nonce,
		sas: sas, confirmNonce: append([]byte(nil), confirm...), receivedAt: now,
		typingRequested: payload.TypingRequested, startSessions: payload.StartSessions,
	}
	waiting := false
	err = c.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		code, ok, err := linkCodeTx(tx, opened.code.nonce)
		if err != nil {
			return err
		}
		switch d, reason := decide(code, ok, opened.device, now); d {
		case decisionUsedByThisDevice:
			return nil
		case decisionRefused:
			out.Refused = reason
			answered, err := refuseHello(tx, request, reason, opened.code.nonce, now)
			out.Unanswered = !answered
			return err
		case decisionValid:
		}
		saved, err := savePending(tx, request)
		if err != nil {
			return err
		}
		switch saved {
		case pendingUnchanged:
			stored, _, err := pendingTx(tx, opened.device)
			out.Code, out.ReceivedAt = stored.sas, stored.receivedAt
			return err
		case pendingCapped:
			out.Refused = wire.RefusedTooManyRequests
			answered, err := refuseHello(tx, request, wire.RefusedTooManyRequests, opened.code.nonce, now)
			out.Unanswered = !answered
			return err
		case pendingSaved:
		}
		out.Code, waiting = sas, true
		return nil
	})
	if err != nil {
		return Pending{}, fmt.Errorf("link: deciding a hello: %w", err)
	}
	switch {
	case waiting:
		log.Printf("hub link: link request from phone %s waits for the owner", out.DeviceID)
		c.emit(PairEvent{Kind: EventSAS, DeviceID: out.DeviceID, Name: out.Name, Code: out.Code})
		c.changed()
	case out.Refused != "" && out.Unanswered:
		log.Printf("hub link: hello from phone %s refused (%s), unanswered", out.DeviceID, out.Refused)
	case out.Refused != "":
		log.Printf("hub link: hello from phone %s refused (%s)", out.DeviceID, out.Refused)
		c.emit(PairEvent{Kind: EventRefused, DeviceID: out.DeviceID, Name: out.Name, Reason: out.Refused})
		c.changed()
	}
	return out, nil
}

// openHello opens env under each kept code's nonce and checks it; every
// failure is ErrHelloDropped, logged by device id or wire name only.
func (c *Center) openHello(zone, wireName string, env []byte) (openedHello, error) {
	codes, err := c.keptCodes()
	if err != nil {
		return openedHello{}, err
	}
	for _, code := range codes {
		nonce, err := base64.RawURLEncoding.DecodeString(code.nonce)
		if err != nil {
			continue
		}
		h, f, err := c.opener.Hello(zone, wireName, env, nonce)
		if errors.Is(err, secure.ErrAuthenticationFailed) {
			continue // sealed under another kept code's nonce
		}
		if err != nil {
			log.Printf("hub link: hello %s malformed (%v): dropped", safeName(wireName), errorClass(err))
			return openedHello{}, fmt.Errorf("%w: malformed", ErrHelloDropped)
		}
		return c.checkHello(wireName, env, h, f, code, nonce)
	}
	log.Printf("hub link: hello %s opens under none of the %d kept codes: dropped", safeName(wireName), len(codes))
	return openedHello{}, fmt.Errorf("%w: no kept code", ErrHelloDropped)
}

// checkHello decodes the payload and checks the keys, the signature with the
// enclosed signing key, and that the payload's device id, the header's
// sender and the record name all are that key's hash.
func (c *Center) checkHello(wireName string, env []byte, h secure.Header, f secure.InnerFrame, code linkCode, nonce []byte) (openedHello, error) {
	drop := func(why string) (openedHello, error) {
		log.Printf("hub link: hello %s %s: dropped", safeName(wireName), why)
		return openedHello{}, fmt.Errorf("%w: %s", ErrHelloDropped, why)
	}
	var hello wire.DeviceHello
	if err := json.Unmarshal(f.Payload, &hello); err != nil {
		return drop("has an undecodable payload")
	}
	sig, err1 := keyBytes(hello.SigningKey)
	kx, err2 := keyBytes(hello.AgreementKey)
	if err1 != nil || err2 != nil {
		return drop("has unusable keys")
	}
	kxPub, err := ecdh.X25519().NewPublicKey(kx)
	if err != nil {
		return drop("has unusable keys")
	}
	// A key ECDH refuses (a low-order point) could never carry a keybox or a relay key.
	shared, err := c.keys.Agreement().ECDH(kxPub)
	clear(shared)
	if err != nil {
		return drop("has unusable keys")
	}
	sigPub := ed25519.PublicKey(sig)
	if _, _, err := secure.OpenHPKE(env, secure.ClassHello, c.keys.Agreement(), secure.HelloInfo(h.Hub, nonce),
		secure.Context{Zone: secure.ZoneRelay, WireName: wireName}, sigPub); err != nil {
		return drop("is not signed by its own key")
	}
	id := secure.DeviceID(sigPub)
	if named, err := secure.ParseID(hello.Device.DeviceID); err != nil || named != id || h.Sender != id ||
		wireName != "hello-"+id.String() {
		return drop("names a device id that is not its signing key's")
	}
	if hello.Device.Scope != wire.ScopePrivate && hello.Device.Scope != wire.ScopeShared {
		return drop("has an unknown scope")
	}
	return openedHello{hello: hello, device: id.String(), code: code, linkNonce: nonce, sigPub: sigPub, kxPub: kxPub}, nil
}

// keyBytes is a public key from the hello: base64url of exactly 32 bytes.
func keyBytes(text string) ([]byte, error) {
	b, err := base64.RawURLEncoding.DecodeString(text)
	if err != nil || len(b) != 32 {
		return nil, errors.New("not a 32-byte key")
	}
	return b, nil
}

// safeName is a hello record name for the log: "hello-<uuid>" only, so a
// crafted name never carries text into it.
func safeName(wireName string) string {
	if rest, ok := strings.CutPrefix(wireName, "hello-"); ok {
		if id, err := secure.ParseID(rest); err == nil {
			return "hello-" + id.String()
		}
	}
	return "(unnamed)"
}

// errorClass is the sentinel an open failed with, never its text.
func errorClass(err error) string {
	for _, s := range []error{secure.ErrWrongHub, secure.ErrWrongSender, secure.ErrNameMismatch, secure.ErrWrongClass,
		secure.ErrSignatureMissing, secure.ErrFrameMalformed, secure.ErrLengthMismatch, secure.ErrTooShort,
		secure.ErrBadMagic, secure.ErrUnsupportedVersion, secure.ErrUnsupportedSuite, secure.ErrUnknownClass} {
		if errors.Is(err, s) {
			return strings.TrimPrefix(s.Error(), "secure: ")
		}
	}
	return "other"
}

// displayName is a hello's device name as the hub shows it (the Swift
// MobileLinkCenter.displayName): control and format characters dropped
// except the emoji joiner, line breaks and whitespace controls a space, runs
// of whitespace one space, trimmed, at most wire.MaxMacNameLength runes
// (the Kit clips grapheme clusters: known gap), "iPhone" when nothing is left.
func displayName(raw string) string {
	var b strings.Builder
	for _, r := range raw {
		switch {
		case unicode.In(r, unicode.Zl, unicode.Zp):
			b.WriteRune(' ')
		case unicode.Is(unicode.Cc, r):
			if unicode.IsSpace(r) {
				b.WriteRune(' ')
			}
		case unicode.Is(unicode.Cf, r):
			if r == '‍' {
				b.WriteRune(r)
			}
		default:
			b.WriteRune(r)
		}
	}
	words := strings.Join(strings.Fields(b.String()), " ")
	clipped := strings.TrimSpace(wire.ClipMacName(words))
	if clipped == "" {
		return "iPhone"
	}
	return clipped
}

// pendingDevice is one pending_devices row.
type pendingDevice struct {
	deviceID, name, model, scope string
	signingKey, agreementKey     []byte
	linkNonce, sas               string
	confirmNonce                 []byte
	receivedAt                   time.Time
	typingRequested              bool
	startSessions                bool
}

const pendingColumns = `device_id, name, model, scope, signing_key, agreement_key, link_nonce, sas,
	confirm_nonce, received_at, typing_requested, start_sessions`

// scanPending reads a row; ok is false for a row missing a key column or the
// confirm nonce (a request from before SAS v2 is never offered for a link).
func scanPending(r interface{ Scan(...any) error }) (pendingDevice, bool, error) {
	var (
		p                  pendingDevice
		name, model, scope sql.NullString
		nonce, sas         sql.NullString
		received           sql.NullFloat64
	)
	if err := r.Scan(&p.deviceID, &name, &model, &scope, &p.signingKey, &p.agreementKey, &nonce, &sas,
		&p.confirmNonce, &received, &p.typingRequested, &p.startSessions); err != nil {
		return pendingDevice{}, false, err
	}
	if p.signingKey == nil || p.agreementKey == nil || !nonce.Valid || !sas.Valid || p.confirmNonce == nil || !received.Valid {
		return pendingDevice{}, false, nil
	}
	p.name, p.model, p.scope = name.String, model.String, scope.String
	if p.scope == "" {
		p.scope = wire.ScopePrivate
	}
	p.linkNonce, p.sas, p.receivedAt = nonce.String, sas.String, fromReal(received.Float64)
	return p, true, nil
}

func pendingTx(tx *sql.Tx, device string) (pendingDevice, bool, error) {
	p, ok, err := scanPending(tx.QueryRow(`SELECT `+pendingColumns+` FROM pending_devices WHERE device_id = ? COLLATE NOCASE`, device))
	if errors.Is(err, sql.ErrNoRows) {
		return pendingDevice{}, false, nil
	}
	return p, ok, err
}

// pendingDevicesTx lists the usable requests, oldest first.
func pendingDevicesTx(tx *sql.Tx) ([]pendingDevice, error) {
	rows, err := tx.Query(`SELECT ` + pendingColumns + ` FROM pending_devices ORDER BY received_at, device_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []pendingDevice
	for rows.Next() {
		p, ok, err := scanPending(rows)
		if err != nil {
			return nil, err
		}
		if ok {
			out = append(out, p)
		}
	}
	return out, rows.Err()
}

// PendingLinks lists the requests waiting for the owner, oldest first, with
// the code each shows.
func (c *Center) PendingLinks() ([]Pending, error) {
	var list []pendingDevice
	err := c.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		var err error
		list, err = pendingDevicesTx(tx)
		return err
	})
	if err != nil {
		return nil, fmt.Errorf("link: reading the requests: %w", err)
	}
	out := make([]Pending, 0, len(list))
	for _, p := range list {
		out = append(out, Pending{DeviceID: strings.ToUpper(p.deviceID), Name: p.name, Code: p.sas, ReceivedAt: p.receivedAt})
	}
	return out, nil
}

type pendingSave int

const (
	pendingSaved pendingSave = iota
	// pendingUnchanged: the same device waits with the same code and keys.
	pendingUnchanged
	// pendingCapped: the code's nonces are spent (or the code is gone).
	pendingCapped
)

// savePending stores p, drawing one of its code's confirm nonces (the Swift
// savePendingDevice): the same device with the same code and keys is
// unchanged and draws none; any other hello for the code — a new device, or
// a known one under new keys — draws one and replaces that device's request,
// until the code has drawn MaxNoncesPerCode.
func savePending(tx *sql.Tx, p pendingDevice) (pendingSave, error) {
	if stored, ok, err := pendingTx(tx, p.deviceID); err != nil {
		return 0, err
	} else if ok && stored.linkNonce == p.linkNonce && bytes.Equal(stored.signingKey, p.signingKey) &&
		bytes.Equal(stored.agreementKey, p.agreementKey) {
		return pendingUnchanged, nil
	}
	drawn, err := drawAnswer(tx, p.linkNonce, MaxNoncesPerCode)
	if err != nil || !drawn {
		return pendingCapped, err
	}
	if _, err := tx.Exec(`DELETE FROM pending_devices WHERE device_id = ? COLLATE NOCASE`, p.deviceID); err != nil {
		return 0, err
	}
	_, err = tx.Exec(`INSERT INTO pending_devices (`+pendingColumns+`, user_record_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '')`,
		strings.ToUpper(p.deviceID), p.name, p.model, p.scope, p.signingKey, p.agreementKey, p.linkNonce, p.sas,
		p.confirmNonce, secs(p.receivedAt), p.typingRequested, p.startSessions)
	return pendingSaved, err
}

// drawAnswer takes one of the code's answers (confirm nonces and refusals
// share link_codes.confirm_nonces_drawn) while fewer than max were drawn.
func drawAnswer(tx *sql.Tx, nonce string, limit int) (bool, error) {
	res, err := tx.Exec(`UPDATE link_codes SET confirm_nonces_drawn = confirm_nonces_drawn + 1
		WHERE nonce = ? AND confirm_nonces_drawn < ?`, nonce, limit)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// refuseHello stores the refusal of a hello under the code codeNonce within
// the flood bounds (the Swift saveBoundedLinkRefusal): a linked phone keeps
// its link (nothing written); a phone that already has a refusal is
// rewritten in place; a new one draws from the code's answers up to
// MaxNoncesPerCode + MaxRefusalsPerCode, and only while fewer than
// MaxLinkRefusals unexpired refusals exist. A code no longer kept has no
// counter: only the total cap applies. false: nothing written.
func refuseHello(tx *sql.Tx, p pendingDevice, reason, codeNonce string, now time.Time) (bool, error) {
	if linked, err := isLinked(tx, p.deviceID); err != nil || linked {
		return false, err
	}
	if _, err := tx.Exec(`DELETE FROM link_refusals WHERE at < ?`, secs(now.Add(-RefusalLifetime))); err != nil {
		return false, err
	}
	var known bool
	if err := tx.QueryRow(`SELECT EXISTS (SELECT 1 FROM link_refusals WHERE device_id = ? COLLATE NOCASE)`, p.deviceID).
		Scan(&known); err != nil {
		return false, err
	}
	if !known {
		var count int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM link_refusals`).Scan(&count); err != nil {
			return false, err
		}
		if count >= MaxLinkRefusals {
			return false, nil
		}
		if _, kept, err := linkCodeTx(tx, codeNonce); err != nil {
			return false, err
		} else if kept {
			drawn, err := drawAnswer(tx, codeNonce, MaxNoncesPerCode+MaxRefusalsPerCode)
			if err != nil || !drawn {
				return false, err
			}
		}
	}
	return true, saveRefusal(tx, p, reason, now)
}

// refusePending refuses a waiting request (the owner's Refuse, an unlink, an
// expiry, another phone's link) and removes it; a linked phone gets no
// refusal. Not bounded: the request already drew its answer.
func refusePending(tx *sql.Tx, p pendingDevice, reason string, now time.Time) error {
	if linked, err := isLinked(tx, p.deviceID); err != nil {
		return err
	} else if !linked {
		if err := saveRefusal(tx, p, reason, now); err != nil {
			return err
		}
	}
	_, err := tx.Exec(`DELETE FROM pending_devices WHERE device_id = ? COLLATE NOCASE`, p.deviceID)
	return err
}

// saveRefusal upserts the phone's one refusal row with the key its keybox is
// sealed to.
func saveRefusal(tx *sql.Tx, p pendingDevice, reason string, at time.Time) error {
	if _, err := tx.Exec(`DELETE FROM link_refusals WHERE device_id = ? COLLATE NOCASE`, p.deviceID); err != nil {
		return err
	}
	_, err := tx.Exec(`INSERT INTO link_refusals (device_id, name, scope, reason, at, agreement_key) VALUES (?, ?, ?, ?, ?, ?)`,
		strings.ToUpper(p.deviceID), p.name, p.scope, reason, secs(at), p.agreementKey)
	return err
}

func isLinked(tx *sql.Tx, device string) (bool, error) {
	var linked bool
	err := tx.QueryRow(`SELECT EXISTS (SELECT 1 FROM devices WHERE device_id = ? COLLATE NOCASE)`, device).Scan(&linked)
	return linked, err
}
