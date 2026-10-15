package briefing

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"strconv"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/prompts"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const emptyBriefingResponse = `{"attention":[],"your_day":[],"what_happened":[],"team_pulse":[],"coaching":[]}`

// seedBriefingAutomation indexes a personal automation named name and enqueues
// one run of it; outputs need both rows.
func seedBriefingAutomation(t *testing.T, d *db.DB, slug, name string) (automationID, runID int64) {
	t.Helper()
	automationID, err := d.UpsertAutomationIndex(db.Automation{
		Slug: slug, Scope: "personal", Path: "/acme/automations/" + slug + ".md", Name: name,
		TriggerKind: "manual", TriggerSpec: `{"manual":true}`, MissedPolicy: "run_once",
		Concurrency: 1, BudgetTokens: 50000, BudgetMinutes: 5, PauseTimeoutHours: 72,
		PermissionsJSON: `["llm"]`, OutputsJSON: `["briefing"]`,
		RecipeText: "---\nname: x\n---\n", ContentHash: "c-" + slug, ApprovalHash: "h-" + slug,
	})
	require.NoError(t, err)
	runID, _, err = d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: automationID, Trigger: db.TriggerManual, Now: time.Now()})
	require.NoError(t, err)
	return automationID, runID
}

func insertAutomationOutput(t *testing.T, d *db.DB, automationID, runID int64, kind, title, body string, at time.Time) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		automationID, runID, kind, title, body, at.UTC().Format("2006-01-02T15:04:05Z"))
	require.NoError(t, err)
}

// briefingOwnerDB is a DB with an owner and nothing else to summarize.
func briefingOwnerDB(t *testing.T) *db.DB {
	t.Helper()
	d := testDB(t)
	require.NoError(t, d.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test"}))
	_, err := d.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, err)
	return d
}

func runBriefingToday(t *testing.T, d *db.DB, store *prompts.Store, logger *log.Logger) (int, *capturingGenerator) {
	t.Helper()
	gen := &capturingGenerator{response: emptyBriefingResponse}
	pipe := New(d, testConfig(), gen, logger)
	if store != nil {
		pipe.SetPromptStore(store)
	}
	id, err := pipe.RunForDate(context.Background(), time.Now().Format("2006-01-02"))
	require.NoError(t, err)
	return id, gen
}

func TestBriefing_IncludesAutomationOutputsSinceLast(t *testing.T) {
	d := briefingOwnerDB(t)
	yesterday := time.Now().AddDate(0, 0, -1)
	prevID, err := d.UpsertBriefing(db.Briefing{UserID: "U001", Date: yesterday.Format("2006-01-02"),
		Attention: "[]", YourDay: "[]", WhatHappened: "[]", TeamPulse: "[]", Coaching: "[]"})
	require.NoError(t, err)
	prevCreated := time.Date(yesterday.Year(), yesterday.Month(), yesterday.Day(), 8, 0, 0, 0, time.Local)
	_, err = d.Exec(`UPDATE briefings SET created_at = ? WHERE id = ?`, prevCreated.UTC().Format(time.RFC3339), prevID)
	require.NoError(t, err)

	a, run := seedBriefingAutomation(t, d, "standup", "Standup notes")
	insertAutomationOutput(t, d, a, run, "briefing", "OLD-OUTPUT-SENTINEL", "before the last briefing", prevCreated.Add(-time.Hour))
	insertAutomationOutput(t, d, a, run, "briefing", "NEW-OUTPUT-SENTINEL", "after the last briefing", prevCreated.Add(time.Hour))

	id, gen := runBriefingToday(t, d, nil, log.New(io.Discard, "", 0))
	require.Greater(t, id, 0)
	assert.Contains(t, gen.systemMsg, "=== FROM YOUR AUTOMATIONS ===\n⚙ Standup notes: NEW-OUTPUT-SENTINEL\nafter the last briefing")
	assert.NotContains(t, gen.systemMsg, "OLD-OUTPUT-SENTINEL", "an output the previous briefing already covered")
	assert.NotContains(t, gen.systemMsg, "%!", "every verb got exactly one argument")
}

func TestBriefing_AutomationSectionBoundedTo4KiBOldestDropped(t *testing.T) {
	d := testDB(t)
	since := time.Now().Add(-2 * time.Hour)
	a, run := seedBriefingAutomation(t, d, "bulk", "Bulk")
	for i := range 10 {
		insertAutomationOutput(t, d, a, run, "briefing", fmt.Sprintf("output-%d", i), strings.Repeat("x", 1024), since.Add(time.Duration(i+1)*time.Minute))
	}
	pipe := New(d, testConfig(), &mockGenerator{}, log.New(io.Discard, "", 0))

	section, has := pipe.gatherAutomationOutputs(since)
	require.True(t, has)
	assert.LessOrEqual(t, len(section), maxAutomationSectionBytes)
	kept := strings.Count(section, "⚙ Bulk: output-")
	require.Positive(t, kept)
	require.Less(t, kept, 10)
	assert.Contains(t, section, "output-9", "the newest output is kept")
	for i := range 10 - kept {
		assert.NotContains(t, section, fmt.Sprintf("output-%d\n", i), "the oldest outputs are dropped first")
	}
	assert.True(t, strings.HasSuffix(section, "\n+"+strconv.Itoa(10-kept)+" more"), "section ends with the dropped count: %q", section[len(section)-20:])
}

// A single body larger than the whole budget (output bodies may reach 64 KiB)
// is clipped, not dropped: the section still says something and stays bounded.
func TestBriefing_AutomationSingleOversizedOutputClipped(t *testing.T) {
	d := testDB(t)
	since := time.Now().Add(-time.Hour)
	a, run := seedBriefingAutomation(t, d, "huge", "Huge")
	insertAutomationOutput(t, d, a, run, "briefing", "old", "short", since.Add(time.Minute))
	insertAutomationOutput(t, d, a, run, "briefing", "big", strings.Repeat("я", 10000), since.Add(2*time.Minute))
	pipe := New(d, testConfig(), &mockGenerator{}, log.New(io.Discard, "", 0))

	section, has := pipe.gatherAutomationOutputs(since)
	require.True(t, has)
	assert.LessOrEqual(t, len(section), maxAutomationSectionBytes)
	assert.True(t, strings.HasPrefix(section, "⚙ Huge: big\n"), "the newest output is kept, clipped")
	assert.True(t, strings.HasSuffix(section, "…\n\n+1 more"))
	assert.NotContains(t, section, "�", "the clip never splits a character")
}

func TestBriefing_AutomationOutputsAloneCountAsData(t *testing.T) {
	d := briefingOwnerDB(t)
	id, _ := runBriefingToday(t, d, nil, log.New(io.Discard, "", 0))
	require.Equal(t, 0, id, "precondition: nothing to summarize")

	a, run := seedBriefingAutomation(t, d, "solo", "Solo")
	insertAutomationOutput(t, d, a, run, "briefing", "Only output", "body", time.Now().Add(-time.Minute))
	id, gen := runBriefingToday(t, d, nil, log.New(io.Discard, "", 0))
	assert.Greater(t, id, 0, "an automation output alone is real material")
	assert.Contains(t, gen.systemMsg, "⚙ Solo: Only output")
}

func TestBriefing_StoredTemplateWithOldVerbCountFallsBack(t *testing.T) {
	d := briefingOwnerDB(t)
	a, run := seedBriefingAutomation(t, d, "notes", "Notes")
	insertAutomationOutput(t, d, a, run, "briefing", "Fallback output", "body", time.Now().Add(-time.Minute))

	const sentinel = "SENTINEL-V11-BRIEFING-5B07"
	verbs := countVerbs(prompts.Defaults[prompts.BriefingDaily])
	require.Equal(t, 17, verbs, "v12 carries 17 verbs")
	v11 := sentinel + "\n" + strings.Repeat("%s\n", verbs-1)
	store := prompts.New(d, nil)
	require.NoError(t, store.Seed())
	require.NoError(t, store.Update(prompts.BriefingDaily, v11, "customized at v11"))

	var logs bytes.Buffer
	id, gen := runBriefingToday(t, d, store, log.New(&logs, "", 0))
	require.Greater(t, id, 0)
	assert.NotContains(t, gen.systemMsg, sentinel, "the v11-shaped template must not be used")
	assert.Contains(t, gen.systemMsg, "=== FROM YOUR AUTOMATIONS ===\n⚙ Notes: Fallback output")
	assert.NotContains(t, gen.systemMsg, "%!")
	assert.Contains(t, logs.String(), "has 16 placeholders, the default has 17 — using the default")
	stored, err := d.GetBriefingByID(id)
	require.NoError(t, err)
	assert.Equal(t, 0, stored.PromptVersion, "a fallback records the default arm's version 0")
}

func TestBriefing_OnlyKindBriefingIncluded(t *testing.T) {
	d := testDB(t)
	since := time.Now().Add(-time.Hour)
	a, run := seedBriefingAutomation(t, d, "mixed", "Mixed")
	insertAutomationOutput(t, d, a, run, "inbox", "INBOX-OUTPUT", "b", since.Add(time.Minute))
	insertAutomationOutput(t, d, a, run, "report", "REPORT-OUTPUT", "b", since.Add(2*time.Minute))
	pipe := New(d, testConfig(), &mockGenerator{}, log.New(io.Discard, "", 0))

	section, has := pipe.gatherAutomationOutputs(since)
	assert.False(t, has, "inbox and report outputs are not briefing material")
	assert.Equal(t, noAutomationOutputs, section)

	insertAutomationOutput(t, d, a, run, "briefing", "BRIEFING-OUTPUT", "b", since.Add(3*time.Minute))
	section, has = pipe.gatherAutomationOutputs(since)
	assert.True(t, has)
	assert.Contains(t, section, "BRIEFING-OUTPUT")
	assert.NotContains(t, section, "INBOX-OUTPUT")
	assert.NotContains(t, section, "REPORT-OUTPUT")
}

func TestBriefing_PromptV12NamesAutomationSection(t *testing.T) {
	tmpl := prompts.Defaults[prompts.BriefingDaily]
	assert.GreaterOrEqual(t, prompts.DefaultVersions[prompts.BriefingDaily], 12, "the new section must auto-upgrade stored v11 rows")
	assert.True(t, strings.HasSuffix(tmpl, "\n=== FROM YOUR AUTOMATIONS ===\n%s"), "the section is the template's last slot")
	assert.Contains(t, tmpl, noAutomationOutputs, "the placeholder the template names is the one rendered")
	assert.Contains(t, tmpl, "never invent ids")
}
