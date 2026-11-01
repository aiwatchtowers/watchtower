package cloudkit

import (
	"context"
	"fmt"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit/bridgepb"
)

// The Shares capability: what Desktop's ShareService did, now asked of the
// bridge. Share URLs are opaque — returned as given, never parsed or logged.

// AccountStatus implements transport.Shares.
func (c *Client) AccountStatus(ctx context.Context) (transport.Account, error) {
	resp, err := c.do(ctx, &bridgepb.Request{Op: &bridgepb.Request_AccountStatus{AccountStatus: &bridgepb.AccountStatus{}}}, false)
	if err != nil {
		return "", fmt.Errorf("cloudkit: account status: %w", err)
	}
	a := resp.GetAccount()
	if a == nil {
		return "", fmt.Errorf("cloudkit: account status: %w", errUnexpected)
	}
	switch s := transport.Account(a.GetStatus()); s {
	case transport.AccountAvailable, transport.AccountNoAccount, transport.AccountRestricted,
		transport.AccountTemporarilyUnavailable, transport.AccountNoEntitlement:
		return s, nil
	}
	return "", fmt.Errorf("cloudkit: account status: unknown state: %w", errUnexpected)
}

// EnsureShares implements transport.Shares.
func (c *Client) EnsureShares(ctx context.Context) (dataURL, relayURL string, err error) {
	resp, err := c.do(ctx, &bridgepb.Request{Op: &bridgepb.Request_EnsureShares{EnsureShares: &bridgepb.EnsureShares{}}}, false)
	if err != nil {
		return "", "", fmt.Errorf("cloudkit: ensure shares: %w", err)
	}
	s := resp.GetShares()
	if s.GetDataUrl() == "" || s.GetRelayUrl() == "" {
		return "", "", fmt.Errorf("cloudkit: ensure shares: no share URL: %w", errUnexpected)
	}
	return s.GetDataUrl(), s.GetRelayUrl(), nil
}

// SetPublicLink implements transport.Shares.
func (c *Client) SetPublicLink(ctx context.Context, open bool) error {
	if err := c.done0(ctx, &bridgepb.Request{Op: &bridgepb.Request_SetPublicLink{SetPublicLink: &bridgepb.SetPublicLink{Open: open}}}, false); err != nil {
		return fmt.Errorf("cloudkit: public link: %w", err)
	}
	return nil
}

// Participants implements transport.Shares; zone is a runtime zone name.
func (c *Client) Participants(ctx context.Context, zoneName string) ([]transport.Participant, error) {
	z, err := c.zone(zoneName)
	if err != nil {
		return nil, err
	}
	resp, err := c.do(ctx, &bridgepb.Request{Op: &bridgepb.Request_Participants{Participants: &bridgepb.Participants{Zone: z.ck}}}, z.mailbox)
	if err != nil {
		return nil, fmt.Errorf("cloudkit: participants: %w", err)
	}
	l := resp.GetParticipants()
	if l == nil {
		return nil, fmt.Errorf("cloudkit: participants: %w", errUnexpected)
	}
	out := make([]transport.Participant, 0, len(l.GetItems()))
	for _, p := range l.GetItems() {
		out = append(out, transport.Participant{UserRecordName: p.GetUserRecordName(), Accepted: p.GetAccepted()})
	}
	return out, nil
}

// RemoveParticipants implements transport.Shares; zone is a runtime zone
// name.
func (c *Client) RemoveParticipants(ctx context.Context, zoneName string, userRecordNames []string) error {
	z, err := c.zone(zoneName)
	if err != nil {
		return err
	}
	if err := c.done0(ctx, &bridgepb.Request{Op: &bridgepb.Request_RemoveParticipants{RemoveParticipants: &bridgepb.RemoveParticipants{
		Zone: z.ck, UserRecordNames: userRecordNames,
	}}}, z.mailbox); err != nil {
		return fmt.Errorf("cloudkit: remove participants: %w", err)
	}
	return nil
}

// done0 sends req and expects Done.
func (c *Client) done0(ctx context.Context, req *bridgepb.Request, mailbox bool) error {
	resp, err := c.do(ctx, req, mailbox)
	if err != nil {
		return err
	}
	if resp.GetDone() == nil {
		return errUnexpected
	}
	return nil
}
