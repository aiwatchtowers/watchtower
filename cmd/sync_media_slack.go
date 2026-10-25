package cmd

import (
	"log"

	"watchtower/internal/issuekey"
	"watchtower/internal/media"
	"watchtower/internal/sync"
)

// wireSlackMedia registers the Slack side of the media pass: the opener
// downloads each account's files through that account's own orchestrator
// client (its token, its rate limiter), and, with issue-key detection on,
// the after-described hook links the keys read off a Slack image. Each
// client's team domain is seeded from slack_accounts.team_domain here, so a
// <team>.slack.com file URL is reachable even when the cycle's first
// ensureWorkspace fails (it sets the domain again when it runs).
func wireSlackMedia(p *media.Pipeline, orchestrators []*sync.Orchestrator, det *issuekey.KeyDetector, logger *log.Logger) {
	clients := make(map[int64]media.SlackFileDownloader, len(orchestrators))
	for _, o := range orchestrators {
		c := o.SlackClient()
		acct, err := p.DB.GetSlackAccount(o.AccountID())
		switch {
		case err != nil:
			logger.Printf("media: slack account %d: %v", o.AccountID(), err)
		case acct.TeamDomain != "":
			c.SetTeamDomain(acct.TeamDomain)
		}
		clients[o.AccountID()] = c
	}
	p.Openers["slack"] = media.SlackOpener{Clients: clients}
	if det != nil {
		p.AfterDescribed = append(p.AfterDescribed, media.SlackAfterDescribed(det))
	}
}
