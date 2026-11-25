package link

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"slices"
	"strings"
	"time"

	"watchtower/internal/hub/wire"
)

// linkNonceLength is the QR nonce: 32 random bytes, 43 base64url characters
// (the Kit's LinkPayload.makeNonce).
const linkNonceLength = 32

// linkCode is one link_codes row. usedBy is "" while unused.
type linkCode struct {
	nonce    string
	issuedAt time.Time
	exp      time.Time
	usedBy   string
}

// cloudKitFields are a CloudKit code's own fields (IssueCloudKit): the
// container, the Mac's iCloud user and the share URLs (nil when the shares
// could not be made: only a same-Apple-ID phone can link then).
type cloudKitFields struct {
	container, ownerUser  string
	dataShare, relayShare *string
}

// Issue makes a new QR code (v4, transport relay, the hub's relay identity
// and transports; no CloudKit fields): every unused code still open is
// retired first, so only the newest links, and link_codes keeps the newest
// KeptCodes. It returns the payload and its URL and emits qr then waiting.
func (c *Center) Issue() (wire.LinkPayload, string, error) { return c.IssueFor("") }

// IssueFor is Issue for the pairing stream token: its qr and waiting events
// carry token, and every event carries the code's nonce (PairEvent).
func (c *Center) IssueFor(token string) (wire.LinkPayload, string, error) {
	return c.issue(nil, token)
}

// issue is IssueFor; ck set makes a CloudKit code (IssueCloudKit): the
// CloudKit fields, transport cloudkit and transports ["cloudkit"], plus
// "relay" only when the host has a relay (HostInfo.Transports): a Mac
// without one never sends a paying phone to a relay that is not there. The
// relay identity stays on the code either way.
func (c *Center) issue(ck *cloudKitFields, token string) (wire.LinkPayload, string, error) {
	c.mu.Lock()
	defer c.unlock()
	raw := make([]byte, linkNonceLength)
	if _, err := rand.Read(raw); err != nil {
		return wire.LinkPayload{}, "", fmt.Errorf("link: random: %w", err)
	}
	now := c.now()
	b64 := base64.RawURLEncoding.EncodeToString
	p := wire.LinkPayload{
		V:             wire.LinkPayloadVersion,
		HubID:         c.keys.HubIDText(),
		MacName:       wire.ClipMacName(c.host.Name),
		Nonce:         b64(raw),
		Iat:           now.Unix(),
		Exp:           now.Add(wire.LinkLifetime).Unix(),
		HubSig:        b64(c.keys.Signer().Public().(ed25519.PublicKey)),
		HubKX:         b64(c.keys.Agreement().PublicKey().Bytes()),
		Transport:     wire.TransportRelay,
		RelayDeviceID: c.host.RelayDeviceID,
		RelayAuthPub:  c.host.RelayAuthPub,
		Transports:    append([]string(nil), c.host.Transports...),
		// This Mac moves itself to Relay when a paying phone links over a
		// pairing slot (switcher.checkRelayLink); wire.LinkPayload.
		RelaySwitch: true,
	}
	if ck != nil {
		p.Container, p.OwnerUser, p.DataShare, p.RelayShare = ck.container, ck.ownerUser, ck.dataShare, ck.relayShare
		p.Transport, p.Transports = wire.TransportCloudKit, []string{wire.TransportCloudKit}
		if slices.Contains(c.host.Transports, wire.TransportRelay) {
			p.Transports = append(p.Transports, wire.TransportRelay)
		}
	}
	url, err := p.URL()
	if err != nil {
		return wire.LinkPayload{}, "", fmt.Errorf("link: rendering the code: %w", err)
	}
	// The CloudKit code a relay code replaces (nil otherwise): read again
	// under ck.mu below; a close that takes it meanwhile refuses its own.
	var replaced *openCode
	if ck == nil {
		c.ck.mu.Lock()
		replaced = c.ck.open
		c.ck.mu.Unlock()
	}
	var refused []pendingDevice
	err = c.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		refused = nil
		if _, err := tx.Exec(`UPDATE link_codes SET exp = ? WHERE used_by_device IS NULL AND exp >= ?`,
			secs(now)-1, secs(now)); err != nil {
			return err
		}
		if replaced != nil {
			// Its waiting phones read expired_code before the replaced code's
			// sweep can take their participants away.
			all, err := pendingDevicesTx(tx)
			if err != nil {
				return err
			}
			for _, pd := range all {
				if pd.linkNonce != replaced.nonce {
					continue
				}
				if err := refusePending(tx, pd, wire.RefusedExpiredCode, now); err != nil {
					return err
				}
				refused = append(refused, pd)
			}
		}
		if _, err := tx.Exec(`INSERT INTO link_codes (nonce, issued_at, exp) VALUES (?, ?, ?)`,
			p.Nonce, float64(p.Iat), float64(p.Exp)); err != nil {
			return err
		}
		_, err := tx.Exec(`DELETE FROM link_codes WHERE nonce NOT IN (
			SELECT nonce FROM link_codes ORDER BY issued_at DESC, rowid DESC LIMIT ?)`, KeptCodes)
		return err
	})
	if err != nil {
		return wire.LinkPayload{}, "", fmt.Errorf("link: storing the code: %w", err)
	}
	for _, pd := range refused {
		// Under the replaced code's nonce: only the stream that asked for that
		// code hears it, never the one asking for this code.
		c.refusedEvent(pd, wire.RefusedExpiredCode)
	}
	if len(refused) > 0 {
		log.Printf("hub link: a relay code replaced the CloudKit code: %d waiting requests refused", len(refused))
	}
	c.ck.mu.Lock()
	c.ck.codeGen++
	if !c.ck.startClosed {
		if c.ck.ownCodes == nil {
			c.ck.ownCodes = map[string]bool{}
		}
		c.ck.ownCodes[p.Nonce] = true
	}
	switch {
	case ck != nil:
		// On screen in the same step that retired every other code: a relay
		// code issued meanwhile can never be displaced by an older one.
		c.ck.open = &openCode{nonce: p.Nonce, exp: time.Unix(p.Exp, 0).UTC()}
	case c.ck.open != nil:
		// A relay code replaces the CloudKit code on screen: off screen now
		// (a close of it refuses nobody waiting on the relay code), closed as
		// an answering close would: its public link at the next pass, its
		// participants after the answer grace (no sweep before it, an
		// unlink's included: sweepSoon). Both stay due while an iCloud hold
		// skips the passes, and the stop closes the link until a close of it
		// lands (closeAtStop).
		c.ck.open = nil
		c.ck.linkCloseAt, c.ck.linkCloseTries, c.ck.closeAtStop = now, 0, true
		c.ck.graceEnd = now.Add(c.sweep.AnswerGrace)
		c.ck.sweepAt, c.ck.sweepTries = c.ck.graceEnd, 0
	}
	if ck == nil {
		c.ck.relayCodes = append(c.ck.relayCodes, p.Nonce)
		if n := len(c.ck.relayCodes); n > KeptCodes {
			c.ck.relayCodes = slices.Delete(c.ck.relayCodes, 0, n-KeptCodes)
		}
	}
	c.ck.mu.Unlock()
	// Emitted under c.mu, before any hello under this code can be decided
	// (decideHello takes c.mu): the asking stream learns the nonce first.
	c.emit(PairEvent{Kind: EventQR, URL: url, ExpiresAt: time.Unix(p.Exp, 0).UTC(), Nonce: p.Nonce, Token: token})
	c.emit(PairEvent{Kind: EventWaiting, Nonce: p.Nonce, Token: token})
	return p, url, nil
}

// keptCodes lists the stored codes, newest first.
func (c *Center) keptCodes() ([]linkCode, error) {
	var out []linkCode
	err := c.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		rows, err := tx.Query(`SELECT nonce, issued_at, exp, used_by_device FROM link_codes ORDER BY issued_at DESC, rowid DESC`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			code, err := scanCode(rows)
			if err != nil {
				return err
			}
			out = append(out, code)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, fmt.Errorf("link: reading the codes: %w", err)
	}
	return out, nil
}

func linkCodeTx(tx *sql.Tx, nonce string) (linkCode, bool, error) {
	code, err := scanCode(tx.QueryRow(`SELECT nonce, issued_at, exp, used_by_device FROM link_codes WHERE nonce = ?`, nonce))
	if errors.Is(err, sql.ErrNoRows) {
		return linkCode{}, false, nil
	}
	if err != nil {
		return linkCode{}, false, err
	}
	return code, true, nil
}

func scanCode(r interface{ Scan(...any) error }) (linkCode, error) {
	var (
		code        linkCode
		issued, exp float64
		used        sql.NullString
	)
	if err := r.Scan(&code.nonce, &issued, &exp, &used); err != nil {
		return linkCode{}, err
	}
	code.issuedAt, code.exp, code.usedBy = fromReal(issued), fromReal(exp), used.String
	return code, nil
}

// decision is what a code does for a device (the Swift LinkDecision).
type decision int

const (
	decisionValid decision = iota
	// decisionUsedByThisDevice: the same code from the same device again.
	decisionUsedByThisDevice
	decisionRefused
)

// decide: a missing code is unknown_code; a used one is the same device's
// (any case) or used_code; an unused one is valid while exp ≥ now (a code is
// still valid at exactly 600 s), else expired_code.
func decide(code linkCode, ok bool, device string, now time.Time) (decision, string) {
	switch {
	case !ok:
		return decisionRefused, wire.RefusedUnknownCode
	case code.usedBy != "" && strings.EqualFold(code.usedBy, device):
		return decisionUsedByThisDevice, ""
	case code.usedBy != "":
		return decisionRefused, wire.RefusedUsedCode
	case code.exp.Before(now):
		return decisionRefused, wire.RefusedExpiredCode
	}
	return decisionValid, ""
}
