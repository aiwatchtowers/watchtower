package targets

import (
	"context"
	"fmt"
	"log"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/logcanary"
)

// TestFILES01_TargetsNeverLogsContent runs extraction, linking, creation and
// next steps over canary targets and text, with an answer that hits every
// validation log line and with unparseable output; returned errors are logged
// the way a caller would.
func TestFILES01_TargetsNeverLogsContent(t *testing.T) {
	c := logcanary.Text
	sink := logcanary.Capture(t)

	// Two invalid links first (they survive the cap of 3), then enough valid
	// ones to hit the cap.
	links := []string{`{"external_ref":"jira:PROJ-9","relation":"` + c("llm.relation") + `"}`,
		`{"external_ref":"` + c("llm.external_ref") + `","relation":"related"}`}
	for i := range 3 {
		links = append(links, fmt.Sprintf(`{"external_ref":"jira:PROJ-%d","relation":"related"}`, i))
	}
	var subs []string
	for range 16 {
		subs = append(subs, `{"text":"`+c("llm.sub_item")+`"}`)
	}
	valid := `{"extracted":[{"text":"` + c("llm.target") + `","intent":"` + c("llm.intent") + `","level":"week",` +
		`"secondary_links":[` + strings.Join(links, ",") + `],"sub_items":[` + strings.Join(subs, ",") + `]},` +
		`{"text":"  "}],"omitted_count":0,"notes":"` + c("llm.notes") + `",` +
		`"title":"` + c("llm.next_step") + `","parent_id":null}`
	invalid := c("llm.output") + ` {"extracted":`

	for _, out := range []string{valid, invalid} {
		gen := &mockGenerator{responses: []string{out}}
		d, err := db.Open(":memory:")
		require.NoError(t, err)
		t.Cleanup(func() { d.Close() })
		id, err := d.CreateTarget(db.Target{Text: c("target.text"), Intent: c("target.intent"), Level: "week",
			Status: "todo", Priority: "high", Ownership: "mine", SourceType: "manual"})
		require.NoError(t, err)
		p := New(d, nil, gen, nil, "", sink.Logger())
		ctx := context.Background()

		res, err := p.Extract(ctx, ExtractRequest{RawText: c("raw.text"), EntryPoint: "cli"})
		log.Printf("extract: %v", err)
		if res != nil {
			_, err = p.CreateFromExtraction(ctx, res.Extracted, "manual", c("source.ref"))
			log.Printf("create: %v", err)
		}
		_, err = p.LinkExisting(ctx, id)
		log.Printf("link: %v", err)
		_, err = p.GenerateNextStep(ctx, int(id))
		log.Printf("next step: %v", err)
	}

	require.Contains(t, sink.String(), "targets/extractor: ", "the pipeline logged nothing; the guard would be vacuous")
	sink.AssertClean(t)
}
