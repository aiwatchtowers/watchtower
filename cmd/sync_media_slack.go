package cmd

import (
	"watchtower/internal/issuekey"
	"watchtower/internal/media"
	"watchtower/internal/sync"
)

// wireSlackMedia registers the Slack side of the media pass: the opener
// downloads each account's files through that account's own orchestrator
// client (its token, its rate limiter), and, with issue-key detection on,
// the after-described hook links the keys read off a Slack image.
func wireSlackMedia(p *media.Pipeline, orchestrators []*sync.Orchestrator, det *issuekey.KeyDetector) {
	clients := make(map[int64]media.SlackFileDownloader, len(orchestrators))
	for _, o := range orchestrators {
		clients[o.AccountID()] = o.SlackClient()
	}
	p.Openers["slack"] = media.SlackOpener{Clients: clients}
	if det != nil {
		p.AfterDescribed = append(p.AfterDescribed, media.SlackAfterDescribed(det))
	}
}
