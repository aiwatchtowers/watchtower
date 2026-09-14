package reactioncmd

import (
	"context"
	"fmt"

	"github.com/slack-go/slack"

	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
)

// seedDetail is the ledger `error` text every seeded row carries, so
// `watchtower reaction-commands list` distinguishes "closed by the enable" from
// the two ordinary skips ("emoji maps to no built-in tool" / "tool not
// registered"). It is a detail string, not a status: seeded rows reuse the
// existing `skipped` status, which already means "recorded, never dispatched".
const seedDetail = "seeded on enable (pre-existing reaction)"

// SeedLedger records every reaction the owner has ALREADY placed as seen —
// status `skipped`, no AI call, no tool dispatch — so enabling the feature
// cannot replay the owner's reaction history as a batch of commands.
//
// It is the reaction-commands fast-forward hook (FEAT-03), called from
// internal/features.FastForward via its deps seam; the poll itself has no
// notion of "just enabled". `reactions.list` carries no time filter
// (internal/slack/client.go), so there is no watermark to stamp: the ledger IS
// the mechanism, and writing it up-front is the only way to make the first poll
// quiet. The wider-than-the-dictionary scope is deliberate — a non-dictionary
// reaction is inert in the ledger (the key includes `emoji`), and seeding it
// closes the replay a later dictionary edit would otherwise re-open.
//
// Fail-closed: any error here fails the enable, which leaves the feature off
// (FEAT-03's ordering). That includes an enabled Slack account accountsFn could
// not resolve a token for — it logs and skips such an account, and an account
// left unseeded is exactly the account whose history would replay.
func SeedLedger(ctx context.Context, database *db.DB, accountsFn func(context.Context) ([]Account, error)) (int, error) {
	accounts, err := accountsFn(ctx)
	if err != nil {
		return 0, fmt.Errorf("resolving reaction accounts: %w", err)
	}
	if err := assertEveryEnabledAccountResolved(database, accounts); err != nil {
		return 0, err
	}
	seeded := 0
	for _, acct := range accounts {
		n, err := seedAccount(ctx, database, acct)
		if err != nil {
			return 0, fmt.Errorf("seeding reaction ledger for account #%d: %w", acct.AccountID, err)
		}
		seeded += n
	}
	return seeded, nil
}

// assertEveryEnabledAccountResolved fails when accountsFn dropped an enabled
// Slack account (its token file is missing or unreadable). Seeding the rest and
// reporting success would arm the feature with one account's whole history
// still unseen.
func assertEveryEnabledAccountResolved(database *db.DB, accounts []Account) error {
	enabled, err := database.ListEnabledSlackAccounts()
	if err != nil {
		return fmt.Errorf("listing enabled slack accounts: %w", err)
	}
	resolved := make(map[int64]bool, len(accounts))
	for _, a := range accounts {
		resolved[a.AccountID] = true
	}
	for _, acct := range enabled {
		if !resolved[acct.ID] {
			return fmt.Errorf("slack account #%d could not be reached (no usable token); "+
				"run 'watchtower slack login --account %d' and enable the feature again", acct.ID, acct.ID)
		}
	}
	return nil
}

// seedAccount records one account's whole reaction history as seen. It reuses
// FilterUnseenReactionCommands so re-running the hook (a second enable after a
// disable) only adds what arrived since, and InsertReactionCommand's
// INSERT OR IGNORE keeps even that a no-op.
func seedAccount(ctx context.Context, database *db.DB, acct Account) (int, error) {
	rawOwner := acct.OwnerID
	if _, raw, ok := watchtowerslack.SplitAccountID(acct.OwnerID); ok {
		rawOwner = raw
	}
	items, err := acct.Lister.ListUserReactions(ctx, rawOwner)
	if err != nil {
		return 0, fmt.Errorf("reactions.list: %w", err)
	}
	reactions := ownerReactionKeys(items, rawOwner, acct.AccountID)
	unseen, err := database.FilterUnseenReactionCommands(acct.AccountID, reactions)
	if err != nil {
		return 0, fmt.Errorf("filtering reaction commands: %w", err)
	}
	for _, u := range unseen {
		if err := database.InsertReactionCommand(u, "skipped", 0, seedDetail); err != nil {
			return 0, err
		}
	}
	return len(unseen), nil
}

// ownerReactionKeys reduces a reactions.list result to every ledger key the
// owner's own reactions occupy, dictionary or not. It is the seed's sibling of
// extractOwnerReactions (extract.go), deliberately separate rather than a
// dictionary-optional branch on it: the two want different outputs (bare ledger
// keys vs dispatchable candidates carrying message context) and extract.go's
// function is already near the complexity gate.
func ownerReactionKeys(items []slack.ReactedItem, ownerRawID string, accountID int64) []db.OwnerReaction {
	var out []db.OwnerReaction
	for _, it := range items {
		if it.Type != "message" || it.Message == nil {
			continue
		}
		ts := it.Message.Timestamp
		if ts == "" {
			ts = it.Timestamp
		}
		if ts == "" || it.Channel == "" {
			continue
		}
		for _, r := range it.Reactions {
			if !reactorIsOwner(r.Users, ownerRawID) {
				continue
			}
			out = append(out, db.OwnerReaction{
				AccountID: accountID,
				ChannelID: watchtowerslack.Namespace(accountID, it.Channel),
				MessageTS: ts,
				Emoji:     r.Name,
			})
		}
	}
	return out
}
