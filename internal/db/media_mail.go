package db

import (
	"context"
	"database/sql"
	"time"
)

// Mail messages are written together with the images found on them (never
// their links): the message row and its media rows commit as one.

// UpsertGmailMessageMedia upserts m and records images on it in one
// transaction. The content time is m.InternalDate; a message without a
// parseable date records no media (RecordMedia needs a content time).
func (db *DB) UpsertGmailMessageMedia(ctx context.Context, accountID int64, m GmailMessage, fromOwner bool, images []MediaFound) error {
	at, err := time.Parse(time.RFC3339, m.InternalDate)
	if len(images) == 0 || err != nil {
		return upsertGmailMessage(ctx, db, accountID, m)
	}
	p := MediaParent{Kind: "gmail", GmailAccountID: accountID, GmailMessageID: m.ID, ContentAt: at, FromOwner: fromOwner}
	return db.WithTx(func(tx *sql.Tx) error {
		if err := upsertGmailMessage(ctx, tx, accountID, m); err != nil {
			return err
		}
		_, err := RecordMedia(ctx, tx, p, images)
		return err
	})
}

// UpsertImapMessageMedia is UpsertGmailMessageMedia for an IMAP message.
func (db *DB) UpsertImapMessageMedia(ctx context.Context, m ImapMessage, syncedAt string, fromOwner bool, images []MediaFound) error {
	at, err := time.Parse(time.RFC3339, m.InternalDate)
	if len(images) == 0 || err != nil {
		return upsertImapMessage(ctx, db, m, syncedAt)
	}
	p := MediaParent{Kind: "imap", IMAPAccountID: m.AccountID, IMAPUIDValidity: m.UIDValidity, IMAPUID: m.UID,
		ContentAt: at, FromOwner: fromOwner}
	return db.WithTx(func(tx *sql.Tx) error {
		if err := upsertImapMessage(ctx, tx, m, syncedAt); err != nil {
			return err
		}
		_, err := RecordMedia(ctx, tx, p, images)
		return err
	})
}
