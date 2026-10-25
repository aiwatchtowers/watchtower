package digest

import (
	"context"
	"fmt"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/logcanary"
)

// TestFILES01_DigestNeverLogsContent runs the channel digests and the
// rollups over channels, users and messages made of canaries, once with a
// valid answer that quotes canaries and once with unparseable output, with
// progress and returned errors routed into the log the way the daemon does.
func TestFILES01_DigestNeverLogsContent(t *testing.T) {
	c := logcanary.Text
	valid := `{"summary":"` + c("llm.summary") + `","running_summary":"` + c("llm.running") + `",` +
		`"topics":[{"title":"` + c("llm.topic") + `","summary":"` + c("llm.topic_summary") + `",` +
		`"decisions":[{"text":"` + c("llm.decision") + `"}],"action_items":[],"situations":[],"key_messages":[]}],` +
		`"channels":[]}`
	batch := `[{"channel_id":"C0","summary":"` + c("llm.batch_summary") + `","topics":[{"title":"` + c("llm.batch_topic") + `"}]},` +
		`{"channel_id":"C1","summary":"` + c("llm.batch_summary") + `"}]`
	invalid := c("llm.output") + ` {"summary":`

	// One channel takes the single-channel path, three take the batch path.
	for _, tc := range []struct {
		channels int
		out      string
	}{{1, valid}, {1, invalid}, {3, batch}, {3, invalid}} {
		out := tc.out
		sink := logcanary.Capture(t)
		database := testDB(t)
		now := time.Now().Unix()
		for ch := range tc.channels {
			chID := fmt.Sprintf("C%d", ch)
			seedChannel(t, database, chID, c(fmt.Sprintf("channel.name%d", ch)))
			for i := range 4 {
				ts := fmt.Sprintf("%d.%06d", now-3600+int64(i*60), ch*10+i)
				seedMessage(t, database, chID, ts, "U1", c("message.text"))
			}
		}
		seedUser(t, database, "U1", c("user.name"), c("user.display_name"))

		p := New(database, testConfig(), &mockGenerator{response: out}, sink.Logger())
		p.OnProgress = func(done, total int, status string) { log.Printf("progress %d/%d %s", done, total, status) }
		_, _, err := p.RunChannelDigests(context.Background())
		log.Printf("channel digests: %v", err)
		_, _, err = p.Run(context.Background())
		log.Printf("run: %v", err)

		require.Contains(t, sink.String(), "digest: ", "the pipeline logged nothing; the guard would be vacuous")
		sink.AssertClean(t)
	}
}
