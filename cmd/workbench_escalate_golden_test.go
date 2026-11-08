package cmd

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/asks"
	"watchtower/internal/db"
)

// escalateGoldenDir holds one file per `workbench escalate-question`
// envelope plus contract.json; the Desktop's decoder tests read the same
// files. Rewrite them with -update.
var escalateGoldenDir = filepath.Join("testdata", "escalate")

// escalateContract is contract.json: the reasons the verb takes, every
// error code it answers and the ones the Desktop retries.
type escalateContract struct {
	Reasons    []string `json:"reasons"`
	ErrorCodes []string `json:"error_codes"`
	Transient  []string `json:"transient"`
}

func TestEscalateEnvelopeGoldens(t *testing.T) {
	for name, res := range map[string]escalateResult{
		"filed_quick": {OK: true, Outcome: escalateFiled, AskID: 42, Level: asks.LevelQuick},
		"filed_full":  {OK: true, Outcome: escalateFiled, AskID: 43, Level: asks.LevelFull},
		"gone":        {OK: true, Outcome: escalateGone},
		"busy":        escalateFailure(escalateErrBusy, errors.New("database is locked")),
		"open_cap":    escalateFailure(escalateErrOpenCap, errEscalateOpenCap),
		"not_found":   escalateFailure(escalateErrNotFound, errors.New("terminal session not found")),
		"bad_args":    escalateFailure(escalateErrBadArgs, errors.New("--session takes a positive id")),
		"schema":      escalateFailure(escalateErrSchema, errors.New("opening database: schema setup failed")),
		"internal":    escalateFailure(escalateErrInternal, errors.New("loading config: no workspace")),
	} {
		t.Run(name, func(t *testing.T) {
			var out bytes.Buffer
			require.NoError(t, writeEscalateResult(&out, res))
			assertEscalateGolden(t, name+".json", out.Bytes())
		})
	}
}

func TestEscalateContractGolden(t *testing.T) {
	contract := escalateContract{
		Reasons: []string{escalateReasonTimeout, escalateReasonLeft, escalateReasonAway},
		ErrorCodes: []string{escalateErrBusy, escalateErrOpenCap, escalateErrNotFound, escalateErrBadArgs,
			escalateErrSchema, escalateErrInternal},
		Transient: []string{escalateErrBusy, escalateErrOpenCap},
	}
	var out bytes.Buffer
	require.NoError(t, writeJSON(&out, contract))
	assertEscalateGolden(t, "contract.json", out.Bytes())
}

// assertEscalateGolden compares got with the golden file, rewriting it
// first under -update.
func assertEscalateGolden(t *testing.T, file string, got []byte) {
	t.Helper()
	path := filepath.Join(escalateGoldenDir, file)
	if *updateSessionReportGolden {
		require.NoError(t, os.MkdirAll(escalateGoldenDir, 0o755))
		require.NoError(t, os.WriteFile(path, got, 0o644))
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err, "run with -update to create it")
	assert.Equal(t, string(want), string(got))
}

// escalateSummaryCase is one entry of summaries.json: the raised ask's
// summary and title as escalatedAsk builds them for a reason (waited
// minutes for a timeout), with what the Desktop drawer shows of it — body
// in the bubble, reason_line as the caption (OwnerAskPresentation
// .summaryParts reads the same file).
type escalateSummaryCase struct {
	Name       string `json:"name"`
	Reason     string `json:"reason"`
	WaitedMin  int    `json:"waited_min"`
	Level      string `json:"level"`
	Question   string `json:"question"`
	Context    string `json:"context"`
	Title      string `json:"title"`
	Summary    string `json:"summary"`
	ReasonLine string `json:"reason_line"`
	Body       string `json:"body"`
}

func TestEscalateSummaryGolden(t *testing.T) {
	full := "Please decide three things before I go on.\n\n" +
		"1. Keep the old endpoint for one release, or drop it now?\n" +
		"2. Rename the flag to --read-folder everywhere?\n\n" +
		"3. Ship it behind the setting, off by default?"
	chat := "Extend `ai query --read-folder` from the workbench folder to the registered worktrees of this " +
		"workbench's sessions (terminal_session_worktrees)?"
	context := "I found two places that read the folder; both assume one root. Extending them is a small change, " +
		"and I recommend yes."
	cases := []struct {
		name, reason string
		waited       time.Duration
		q            db.ChatQuestion
		body         string
	}{
		{"left_with_context", escalateReasonLeft, 0, db.ChatQuestion{Question: chat, Context: context}, context},
		{"away_no_context", escalateReasonAway, 0, db.ChatQuestion{Question: chat}, ""},
		{"timeout_0_with_context", escalateReasonTimeout, 30 * time.Second, db.ChatQuestion{Question: chat, Context: context}, context},
		{"timeout_12_no_context", escalateReasonTimeout, 12*time.Minute + 40*time.Second, db.ChatQuestion{Question: chat}, ""},
		{"full_timeout_12", escalateReasonTimeout, 12 * time.Minute, db.ChatQuestion{Question: full, Level: asks.LevelFull}, ""},
		{"full_left", escalateReasonLeft, 0, db.ChatQuestion{Question: full, Level: asks.LevelFull}, ""},
	}
	out := make([]escalateSummaryCase, 0, len(cases))
	for _, c := range cases {
		line := escalateReasonLine(c.reason, c.waited)
		out = append(out, escalateSummaryCase{
			Name: c.name, Reason: c.reason, WaitedMin: int(c.waited / time.Minute), Level: c.q.Level,
			Question: c.q.Question, Context: c.q.Context,
			Title:      clipRunes(oneLine(c.q.Question), asks.MaxTitleRunes),
			Summary:    escalatedSummary(c.q, line),
			ReasonLine: line, Body: c.body,
		})
	}
	var buf bytes.Buffer
	require.NoError(t, writeJSON(&buf, out))
	assertEscalateGolden(t, "summaries.json", buf.Bytes())
}
