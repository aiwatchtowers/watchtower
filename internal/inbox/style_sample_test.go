package inbox

import (
	"context"
	"fmt"
	"log"
	"testing"

	"watchtower/internal/digest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// erroringGen is a digest.Generator that always fails, modeled on countingGen.
type erroringGen struct {
	calls int
}

func (g *erroringGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	return "", nil, "", fmt.Errorf("ai down")
}

func TestStyleSample_HappyPathStoresProfile(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	insertChannel(t, d, "C1", "public")
	insertChannel(t, d, "D1", "dm")
	insertMessage(t, d, "C1", "100.1", "U1", "деплой откатил, смотрю логи")
	insertMessage(t, d, "D1", "101.1", "U1", "ок, завтра созвонимся по клауду")
	insertMessage(t, d, "C1", "102.1", "U2", "someone else's message — must be excluded")

	gen := &countingGen{response: "You write tersely, RU with the team."}
	p := New(d, testConfig(), gen, log.Default())

	require.NoError(t, p.GenerateStyleProfile(context.Background()))

	assert.Equal(t, 1, gen.calls)
	got, err := d.GetStyleProfile()
	require.NoError(t, err)
	assert.Equal(t, "You write tersely, RU with the team.", got)
}

func TestStyleSample_EmptySampleNoAICallProfileUntouched(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	require.NoError(t, d.SetStyleProfile("existing profile"))

	gen := &countingGen{}
	p := New(d, testConfig(), gen, log.Default())

	err := p.GenerateStyleProfile(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not enough messages")
	assert.Equal(t, 0, gen.calls)
	got, _ := d.GetStyleProfile()
	assert.Equal(t, "existing profile", got, "empty sample must not touch the stored profile")
}

func TestStyleSample_AIErrorLeavesProfileUntouched(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U1", "a message long enough to qualify")
	require.NoError(t, d.SetStyleProfile("existing profile"))

	gen := &erroringGen{}

	p := New(d, testConfig(), gen, log.Default())

	require.Error(t, p.GenerateStyleProfile(context.Background()))
	got, _ := d.GetStyleProfile()
	assert.Equal(t, "existing profile", got)
}

func TestStyleSample_NoWorkspaceErrorsCleanly(t *testing.T) {
	d := newTestDB(t) // deliberately no seedWorkspaceAndUser: fresh DB, empty workspace table

	gen := &countingGen{}
	p := New(d, testConfig(), gen, log.Default())

	err := p.GenerateStyleProfile(context.Background())
	require.Error(t, err, "workspace-less DB must yield a clean error, not a panic")
	assert.Contains(t, err.Error(), "no current user id")
	assert.Equal(t, 0, gen.calls)
}

func TestStyleSample_CapsPerChannelAndTotal(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	insertChannel(t, d, "C1", "public")
	for i := 0; i < 40; i++ {
		insertMessage(t, d, "C1", fmt.Sprintf("%d.1", 100+i), "U1", fmt.Sprintf("message number %d long enough", i))
	}

	msgs, err := d.ListStyleSampleMessages("U1", 1000)
	require.NoError(t, err)
	capped := capStyleSample(msgs, 15, 150)
	assert.Len(t, capped, 15, "per-channel cap of 15 must hold")
}

func TestStyleSample_TotalCapAcrossChannels(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	// 12 channels x 15 qualifying messages = 180 after the per-channel cap,
	// so only the 150 total cap can trim the sample.
	for c := 0; c < 12; c++ {
		chID := fmt.Sprintf("C%02d", c)
		insertChannel(t, d, chID, "public")
		for i := 0; i < 15; i++ {
			insertMessage(t, d, chID, fmt.Sprintf("%d.%d", 1000+c*100+i, c), "U1",
				fmt.Sprintf("channel %d message %d long enough", c, i))
		}
	}

	msgs, err := d.ListStyleSampleMessages("U1", 1000)
	require.NoError(t, err)
	require.Len(t, msgs, 180)
	capped := capStyleSample(msgs, 15, 150)
	assert.Len(t, capped, 150, "total cap of 150 must hold across channels")
}
