package link

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
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

// Issue makes a new QR code (v4, transport relay, the hub's relay identity
// and transports; no CloudKit fields): every unused code still open is
// retired first, so only the newest links, and link_codes keeps the newest
// KeptCodes. It returns the payload and its URL and emits qr then waiting.
func (c *Center) Issue() (wire.LinkPayload, string, error) {
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
		HubID:         c.keys.HubID().String(),
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
	}
	url, err := p.URL()
	if err != nil {
		return wire.LinkPayload{}, "", fmt.Errorf("link: rendering the code: %w", err)
	}
	err = c.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		if _, err := tx.Exec(`UPDATE link_codes SET exp = ? WHERE used_by_device IS NULL AND exp >= ?`,
			secs(now)-1, secs(now)); err != nil {
			return err
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
	c.emit(PairEvent{Kind: EventQR, URL: url, ExpiresAt: time.Unix(p.Exp, 0).UTC()})
	c.emit(PairEvent{Kind: EventWaiting})
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
