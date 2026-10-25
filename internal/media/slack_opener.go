package media

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/slack"
)

// SlackFileDownloader is the account's Slack client as SlackOpener uses it
// (*slack.Client: the account's token, only to Slack's file hosts, inside
// the shared rate limiter).
type SlackFileDownloader interface {
	DownloadFile(ctx context.Context, fileURL string, limit int64) (io.ReadCloser, string, error)
}

// SlackOpener opens Slack image files through the client of the account
// the item's namespaced channel belongs to. An item without a URL (an
// external file), a file Slack no longer has and a URL off Slack's file
// hosts are ErrGone; an account without a client is a failed attempt.
type SlackOpener struct {
	Clients map[int64]SlackFileDownloader
}

func (o SlackOpener) Open(ctx context.Context, it db.MediaItem, limit int64) (io.ReadCloser, string, error) {
	if it.FetchURL == "" {
		return nil, "", ErrGone
	}
	acct, _, ok := slack.SplitAccountID(it.SlackChannelID)
	c := o.Clients[acct]
	if !ok || c == nil {
		return nil, "", fmt.Errorf("media: no Slack client for account %d", acct)
	}
	body, typ, err := c.DownloadFile(ctx, it.FetchURL, limit)
	if err != nil {
		return nil, "", slackOpenError(err)
	}
	return slackBody{body}, typ, nil
}

// slackOpenError maps the client's download errors onto the pass's.
func slackOpenError(err error) error {
	switch {
	case errors.Is(err, slack.ErrFileGone), errors.Is(err, slack.ErrFileURLRefused):
		return ErrGone
	case errors.Is(err, slack.ErrTooLarge):
		return ErrTooLarge
	}
	return err
}

// slackBody reports the client's read-time size refusal as ErrTooLarge.
type slackBody struct{ io.ReadCloser }

func (b slackBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if errors.Is(err, slack.ErrTooLarge) {
		err = ErrTooLarge
	}
	return n, err
}

// SlackKeyDetector links the issue keys a Slack message mentions
// (*issuekey.KeyDetector).
type SlackKeyDetector interface {
	ProcessMessage(channelID, messageTS, text string) (int, error)
}

// SlackAfterDescribed is the pass's after-described hook for Slack: the
// title, description and text read off a Slack image are run through the
// key detector as that message's text, so a screenshot naming an issue
// links it. A link summary never feeds the detector (a page someone else
// wrote is no mention by the message).
func SlackAfterDescribed(d SlackKeyDetector) func(context.Context, db.MediaItem) error {
	return func(_ context.Context, it db.MediaItem) error {
		if it.ParentKind != "slack" || it.Kind != "image" || it.Status != "ok" {
			return nil
		}
		_, err := d.ProcessMessage(it.SlackChannelID, it.SlackTS, strings.Join([]string{it.Title, it.Body, it.ImageText}, "\n"))
		return err
	}
}
