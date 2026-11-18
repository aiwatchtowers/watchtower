package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"watchtower/internal/asks"
	"watchtower/internal/db"
	"watchtower/internal/workbenchfolders"
)

// SuggestWorkbenchFolderTool is the agent's suggestion to put a folder on
// its bench (spec 2026-11-18 §6.7).
const SuggestWorkbenchFolderTool = "suggest_workbench_folder"

// CodeDeclined refuses a suggestion of a folder the owner declined for the
// bench ("Never for This Folder").
const CodeDeclined = "declined"

// maxWhyRunes caps suggest_workbench_folder's why.
const maxWhyRunes = 2000

type suggestFolderArgs struct {
	Path   string `json:"path" jsonschema:"the folder to put on the bench: absolute, usually the repository root the hook named"`
	Why    string `json:"why" jsonschema:"one or two sentences for the owner: why this task needs the folder, at most 2000 characters"`
	Reason string `json:"reason" jsonschema:"one sentence: why you suggest it now"`
}

// suggestion is a checked suggestion: the folder as the bench would store
// it, its repository root, and the bench it is on when another one's.
type suggestion struct {
	bench  *db.Workbench
	folder string
	root   string
	other  *db.Workbench
}

// NewSuggestWorkbenchFolder files a `folder` ask: the owner decides whether
// the folder goes on the bench (spec §6.7). One open ask per bench and
// folder: a second call answers the open one.
func NewSuggestWorkbenchFolder(sessionEnv func() string) *Tool {
	return &Tool{
		Name: SuggestWorkbenchFolderTool,
		Description: "Suggest putting a folder on this workbench when your task keeps working outside its folders " +
			"(workbench_info lists them). It files an ask the owner answers with Put on Bench, Not Now or Never for " +
			"This Folder, and returns at once with {ask_id, status, path, repo_root}; the answer reaches you like any " +
			"ask's. A second call for the same folder returns the open ask (existing: true). Refused with " +
			"`declined` for a folder the owner said never to, and with `not_found`, `already_here` or `nested` as " +
			"putting it on the bench would be. A folder on another workbench is no refusal: the owner is offered to " +
			"merge the benches (other_bench in the result). Applied immediately.",
		InputSchema: mustSchema[suggestFolderArgs](SuggestWorkbenchFolderTool),
		Access:      AccessWrite,
		Surfaces:    workbenchSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a suggestFolderArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.Path) == "" {
				return &ValidationError{Msg: "path is required"}
			}
			return requireText("why", a.Why, maxWhyRunes)
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a suggestFolderArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			_, err := checkSuggestion(ctx, d, b, a.Path)
			return err
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a suggestFolderArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding %s args: %w", SuggestWorkbenchFolderTool, err)
			}
			s, err := checkSuggestion(ctx, d, call.Binding, a.Path)
			if err != nil {
				return nil, err
			}
			return fileFolderAsk(ctx, d, s, strings.TrimSpace(a.Why), sessionEnv)
		},
	}
}

// checkSuggestion is the suggestion's checks, read-only: the folder as Add
// would take it (workbenchfolders.Suggestable) and the owner's declines of
// the folder or its repository root.
func checkSuggestion(ctx context.Context, d *db.DB, b Binding, path string) (suggestion, error) {
	p, err := workbenchOf(ctx, d, b)
	if err != nil {
		return suggestion{}, err
	}
	folder, other, err := workbenchfolders.Suggestable(ctx, d, p.ID, path)
	if err != nil {
		if errors.Is(err, db.ErrWorkbenchFolderNotAllowed) {
			return suggestion{}, &ValidationError{Msg: "not_allowed: " + err.Error(), Err: err}
		}
		return suggestion{}, refusalAsValidation(err)
	}
	root, ok := workbenchfolders.RepoRoot(folder)
	if !ok {
		root = folder
	}
	for _, f := range []string{folder, root} {
		declined, err := d.FolderDeclined(ctx, d, p.ID, f)
		if err != nil {
			return suggestion{}, err //nolint:wrapcheck // db's message names the workbench
		}
		if declined {
			return suggestion{}, &ValidationError{Msg: fmt.Sprintf("%s: The owner does not want %s on this bench.",
				CodeDeclined, filepath.Base(folder))}
		}
	}
	return suggestion{bench: p, folder: folder, root: root, other: other}, nil
}

// fileFolderAsk files the folder ask of s, or answers the bench's open one
// for the same folder; both inside one write transaction, so two calls
// never file two.
func fileFolderAsk(ctx context.Context, d *db.DB, s suggestion, why string, sessionEnv func() string) (any, error) {
	session, err := terminalSessionOf(d, s.bench.ID, sessionEnv)
	if err != nil {
		return nil, err
	}
	payload := db.FolderAskPayload{Path: s.folder, RepoRoot: s.root, Why: why}
	if session.Valid {
		if payload.Touches, err = d.OutsideTouches(ctx, session.Int64, s.root); err != nil {
			return nil, err //nolint:wrapcheck // db's message names the session
		}
	}
	if s.other != nil {
		payload.OtherBench = &db.FolderAskOthers{ID: s.other.ID, Name: s.other.Name}
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("encoding the folder ask's payload: %w", err)
	}
	ask := db.OwnerAsk{
		WorkbenchID: s.bench.ID, SessionID: session, Kind: db.AskKindFolder,
		Title:   fmt.Sprintf("Put %s on the bench?", filepath.Base(s.folder)),
		Summary: why, Payload: string(raw), Origin: asks.OriginAgent,
	}
	var id int64
	existing := false
	err = d.WithTx(func(tx *sql.Tx) error {
		if id, err = d.OpenFolderAsk(tx, s.bench.ID, s.folder); err != nil || id != 0 {
			existing = id != 0
			return err
		}
		id, _, err = d.InsertOwnerAsk(tx, ask)
		return err
	})
	if errors.Is(err, db.ErrTooManyOpenAsks) {
		return nil, &ValidationError{Msg: err.Error(), Err: err}
	}
	if err != nil {
		return nil, err //nolint:wrapcheck // db's message names the ask
	}
	out := map[string]any{"ask_id": id, "status": "open", "path": s.folder, "repo_root": s.root}
	if existing {
		out["existing"] = true
	}
	if s.other != nil {
		out["other_bench"] = map[string]any{"id": s.other.ID, "name": s.other.Name}
	}
	return out, nil
}
