package cmd

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/asks"
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
