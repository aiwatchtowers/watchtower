package chatstore

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"watchtower/internal/chat"
	"watchtower/internal/db"
	"watchtower/internal/slackconnector"
)

// FlushInterval is ChatTurnDriver.flushInterval: streamed text is written at
// most once per interval while it runs.
const FlushInterval = time.Second

// Persisted statuses of an assistant row.
const (
	StatusComplete = "complete"
	StatusPartial  = "partial"
	StatusError    = "error"
)

const codeQuotaExhausted = "quota_exhausted"

// knownErrorCodes is Swift's ChatErrorCode: any other wire code is stored
// as "internal".
var knownErrorCodes = map[string]bool{
	chat.CodeAuth: true, chat.CodeRateLimit: true, codeQuotaExhausted: true, chat.CodeProviderUnavailable: true,
	chat.CodeSessionLost: true, chat.CodeAttachmentUnsupported: true, chat.CodeInterrupted: true,
	chat.CodeInternal: true, chat.CodeWorkDirUnsafe: true,
}

// Failure is a failed (or cut) turn's error, as the assistant row keeps it.
type Failure struct {
	Code, Message string
	// Reason is the routing reason of the error event (quota_exhausted,
	// required_capability_missing), which refines the stored code.
	Reason string
}

// PersistenceCode is ChatSessionError.persistenceCode: the code the row stores.
func (f Failure) PersistenceCode() string {
	switch f.Reason {
	case "quota_exhausted":
		return codeQuotaExhausted
	case "required_capability_missing":
		return chat.CodeAttachmentUnsupported
	}
	if knownErrorCodes[f.Code] {
		return f.Code
	}
	return chat.CodeInternal
}

// StepState is a live step's state.
type StepState string

const (
	StepRunning   StepState = "running"
	StepSucceeded StepState = "succeeded"
	StepFailed    StepState = "failed"
	StepWaiting   StepState = "waiting"
)

// Step is one tool call of the running turn, for the live feed.
type Step struct {
	ToolID, Name, ArgsJSON string
	State                  StepState
	ActionID               int64 // the agent_actions row a waiting step waits on
	Summary                string
	Sources                []chat.Source
	StartedAt              time.Time
	EndedAt                *time.Time
}

type usage struct {
	in, out int
	model   string
}

// Turn folds one running turn's events into the database, as ChatTurnDriver
// and ChatTurnStore do: text flushed at most once per FlushInterval (the
// first delta at once), steps written as they happen (CHAT-02), the end
// written once in one transaction. Apply, Flush and Finalize run on one
// goroutine; Text and Steps may be read from any.
type Turn struct {
	s         *Store
	conv      int64
	messageID int64
	turnID    string
	projectID *int64

	mu        sync.Mutex
	text      strings.Builder
	steps     []Step
	usage     *usage
	lastFlush time.Time // zero = never: the first delta flushes
	sessionID string
	done      bool
	status    string
	gone      bool
}

// Turn begins tracking st's turn (its assistant row already exists).
func (s *Store) Turn(st Started) *Turn {
	return &Turn{s: s, conv: st.ConversationID, messageID: st.AssistantMessageID, turnID: st.TurnID, projectID: st.ProjectID}
}

// Text is the turn's text so far.
func (t *Turn) Text() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.text.String()
}

// Steps is a copy of the turn's steps so far.
func (t *Turn) Steps() []Step {
	t.mu.Lock()
	defer t.mu.Unlock()
	return append([]Step(nil), t.steps...)
}

// Done reports whether the turn ended, and its stored status.
func (t *Turn) Done() (bool, string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.done, t.status
}

// Apply folds one session event (ChatTurnDriver.apply). A turn_done or a
// turn-scoped error ends the turn (one Finalize); events of another turn and
// events after the end are ignored. ErrConversationGone: the conversation
// was deleted — nothing more is written for this turn.
func (t *Turn) Apply(ev chat.Event) error {
	if t.gone {
		return ErrConversationGone
	}
	if t.done {
		return nil
	}
	mine := ev.TurnID == t.turnID
	switch ev.Type {
	case chat.EventSessionReady:
		if err := t.recordSession(ev.SessionID); err != nil {
			return err
		}
		return t.recordActual(ev)
	case chat.EventTextDelta:
		if !mine {
			return nil
		}
		t.mu.Lock()
		t.text.WriteString(ev.Text)
		t.mu.Unlock()
		if t.s.now().Sub(t.lastFlush) >= FlushInterval {
			return t.Flush()
		}
	case chat.EventToolStart:
		if mine {
			return t.stepStarted(ev.ID, ev.Name, argsJSON(ev.Args))
		}
	case chat.EventToolEnd:
		if mine {
			return t.stepFinished(ev)
		}
	case chat.EventToolWait:
		// All four fields always come; one missing is a broken line.
		if mine && ev.ID != "" && ev.Message != "" && ev.ActionID > 0 {
			return t.stepWaiting(ev)
		}
	case chat.EventUsage:
		if mine {
			t.usage = &usage{in: ev.TokensIn, out: ev.TokensOut, model: ev.Model}
		}
	case chat.EventTurnDone:
		if err := t.recordSession(ev.SessionID); err != nil {
			return err
		}
		if !mine {
			return nil
		}
		if ev.Status == chat.StatusComplete {
			return t.finalize(StatusComplete, nil)
		}
		return t.finalize(StatusPartial, nil) // interrupted, or an unknown status: Continue stays offered
	case chat.EventError:
		// A session-level error (no turn id) also ends the running turn.
		if ev.TurnID != "" && !mine {
			return nil
		}
		f := &Failure{Code: ev.Code, Message: ev.Message, Reason: ev.Reason}
		status := StatusError
		if f.PersistenceCode() == codeQuotaExhausted && t.Text() != "" {
			status = StatusPartial
		}
		return t.finalize(status, f)
	}
	return nil
}

// Flush writes the text so far as `partial`, with the usage held.
func (t *Turn) Flush() error {
	if t.gone {
		return ErrConversationGone
	}
	if t.done {
		return nil
	}
	t.lastFlush = t.s.now()
	return t.write(func(tx *sql.Tx) error {
		if err := updateAssistantTx(tx, t.messageID, t.Text(), StatusPartial, t.usage, nil); err != nil {
			return err
		}
		return setModelTx(tx, t.messageID, t.usage)
	})
}

// Finalize ends the turn with status (complete, partial or error) — the
// Stop watchdog, a process death, the daemon's stop — in one transaction:
// the row's text, status, tokens and error, its model, the Live Slack
// backstop mark, the artifacts (not for an error) and the lease release
// (ChatTurnStore.finalizeTurn). A second call is a no-op.
func (t *Turn) Finalize(status string, failure *Failure) error {
	if t.gone {
		return ErrConversationGone
	}
	if t.done {
		return nil
	}
	switch status {
	case StatusComplete, StatusPartial, StatusError:
	default:
		return fmt.Errorf("chatstore: invalid final status %q", status)
	}
	return t.finalize(status, failure)
}

func (t *Turn) finalize(status string, failure *Failure) error {
	t.mu.Lock()
	t.done, t.status = true, status
	for i := range t.steps {
		// A call still waiting when the turn ends never ran: it reads as stopped.
		if t.steps[i].State == StepWaiting {
			t.steps[i].State, t.steps[i].Summary, t.steps[i].ActionID = StepRunning, "", 0
		}
	}
	t.mu.Unlock()
	text := t.Text()
	createdAt := seconds(t.s.now())
	err := t.write(func(tx *sql.Tx) error {
		if err := updateAssistantTx(tx, t.messageID, text, status, t.usage, failure); err != nil {
			return err
		}
		if err := setModelTx(tx, t.messageID, t.usage); err != nil {
			return err
		}
		if err := markIfUsedTx(tx, t.conv, t.messageID); err != nil {
			return err
		}
		if status != StatusError {
			for _, a := range ParseArtifacts(text, true) {
				if err := saveArtifactVersionTx(tx, t.conv, t.messageID, a, createdAt); err != nil {
					return err
				}
			}
		}
		return db.ReleaseChatLeaseTx(tx, t.conv, t.turnID)
	})
	if err != nil {
		return err
	}
	t.s.titleIfNeeded(t.conv)
	return nil
}

// write runs fn in one transaction; a conversation deleted under the turn
// (a 0-row update by id, a foreign-key failure) marks the turn gone.
func (t *Turn) write(fn func(*sql.Tx) error) error {
	err := t.s.db.WithTx(fn)
	if errors.Is(err, ErrConversationGone) || isForeignKeyFailure(err) {
		t.gone = true
		return ErrConversationGone
	}
	return err
}

func isForeignKeyFailure(err error) bool {
	return err != nil && strings.Contains(err.Error(), "FOREIGN KEY constraint failed")
}

func (t *Turn) recordSession(sid string) error {
	if sid == "" || sid == t.sessionID {
		return nil
	}
	t.sessionID = sid
	return t.write(func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE chat_conversations SET session_id = ?, updated_at = ? WHERE id = ? AND project_id IS ?`,
			sid, seconds(t.s.now()), t.conv, t.projectID)
		return err
	})
}

// recordActual is ChatTurnStore.saveActual: the conversation's actual pair
// (a no-op once it moved to another project) and the turn's row.
func (t *Turn) recordActual(ev chat.Event) error {
	if ev.Provider == "" {
		return nil
	}
	reason := ""
	if ev.RoutingMode != "" {
		reason = ev.Reason
	}
	return t.write(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`UPDATE chat_conversations SET actual_provider = ?, actual_model = ?, routing_reason = ?
			WHERE id = ? AND project_id IS ?`, ev.Provider, ev.Model, reason, t.conv, t.projectID); err != nil {
			return err
		}
		res, err := tx.Exec(`UPDATE chat_messages SET provider = ?, model = ? WHERE id = ? AND conversation_id = ?`,
			ev.Provider, ev.Model, t.messageID, t.conv)
		return requireRow(res, err)
	})
}

// stepStarted is LiveTurn.startStep + ChatStepQueries.upsertStart +
// LiveSlackMark.markIfSlackStep: the step's seq is its place in the turn.
func (t *Turn) stepStarted(id, name, args string) error {
	now := t.s.now()
	t.mu.Lock()
	seq := -1
	for i := range t.steps {
		if t.steps[i].ToolID == id {
			seq = i
			if t.steps[i].Name == "" {
				t.steps[i].Name, t.steps[i].ArgsJSON = name, args
			}
			break
		}
	}
	if seq < 0 {
		t.steps = append(t.steps, Step{ToolID: id, Name: name, ArgsJSON: args, State: StepRunning, StartedAt: now})
		seq = len(t.steps) - 1
	}
	t.mu.Unlock()
	return t.write(func(tx *sql.Tx) error {
		if err := requireMessageTx(tx, t.messageID); err != nil {
			return err
		}
		var existing int64
		err := tx.QueryRow(`SELECT id FROM chat_turn_steps WHERE message_id = ? AND tool_id = ?`, t.messageID, id).Scan(&existing)
		switch {
		case err == nil:
			_, err = tx.Exec(`UPDATE chat_turn_steps SET name = ?, args_json = ?, started_at = ? WHERE id = ?`,
				name, args, seconds(now), existing)
		case errors.Is(err, sql.ErrNoRows):
			_, err = tx.Exec(`INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, args_json, started_at)
				VALUES (?, ?, ?, ?, ?, ?)`, t.messageID, seq, id, name, args, seconds(now))
		}
		if err != nil {
			return err
		}
		if !isSlackConnectorStep(name) {
			return nil
		}
		_, err = tx.Exec(`UPDATE chat_conversations SET live_slack_since = ?
			WHERE id = (SELECT conversation_id FROM chat_messages WHERE id = ?) AND live_slack_since IS NULL`,
			t.messageID, t.messageID)
		return err
	})
}

// stepFinished is LiveTurn.finishStep + ChatStepQueries.finish, then a
// forced flush. A tool_end whose tool_start never came is still a step.
func (t *Turn) stepFinished(ev chat.Event) error {
	now := t.s.now()
	ok := ev.OK != nil && *ev.OK
	state := StepFailed
	if ok {
		state = StepSucceeded
	}
	t.mu.Lock()
	found := false
	for i := range t.steps {
		if t.steps[i].ToolID == ev.ID {
			t.steps[i].State, t.steps[i].Summary, t.steps[i].Sources, t.steps[i].ActionID = state, ev.Summary, ev.Sources, 0
			t.steps[i].EndedAt = &now
			found = true
			break
		}
	}
	if !found {
		t.steps = append(t.steps, Step{ToolID: ev.ID, ArgsJSON: "{}", State: state, Summary: ev.Summary,
			Sources: ev.Sources, StartedAt: now, EndedAt: &now})
	}
	t.mu.Unlock()
	okFlag, sources, ended := 0, sourcesJSON(ev.Sources), seconds(now)
	if ok {
		okFlag = 1
	}
	err := t.write(func(tx *sql.Tx) error {
		if err := requireMessageTx(tx, t.messageID); err != nil {
			return err
		}
		res, err := tx.Exec(`UPDATE chat_turn_steps SET ok = ?, summary = ?, sources_json = ?, ended_at = ?
			WHERE message_id = ? AND tool_id = ?`, okFlag, ev.Summary, sources, ended, t.messageID, ev.ID)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			return nil
		}
		_, err = tx.Exec(`INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, ok, summary, sources_json, started_at, ended_at)
			VALUES (?, (SELECT COALESCE(MAX(seq) + 1, 0) FROM chat_turn_steps WHERE message_id = ?), ?, '', ?, ?, ?, ?, ?)`,
			t.messageID, t.messageID, ev.ID, okFlag, ev.Summary, sources, ended, ended)
		return err
	})
	if err != nil {
		return err
	}
	return t.Flush()
}

// stepWaiting: a wait whose tool_start never came persists a nameless start
// first (CHAT-02); the wait itself is live only.
func (t *Turn) stepWaiting(ev chat.Event) error {
	t.mu.Lock()
	idx := -1
	for i := range t.steps {
		if t.steps[i].ToolID == ev.ID {
			idx = i
			break
		}
	}
	t.mu.Unlock()
	if idx < 0 {
		if err := t.stepStarted(ev.ID, "", "{}"); err != nil {
			return err
		}
		idx = len(t.Steps()) - 1
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	switch t.steps[idx].State {
	case StepSucceeded, StepFailed: // a late wait never reopens a finished step
	default:
		t.steps[idx].State, t.steps[idx].ActionID, t.steps[idx].Summary = StepWaiting, ev.ActionID, ev.Message
	}
	return nil
}

func isSlackConnectorStep(name string) bool {
	return strings.HasPrefix(name, slackconnector.ClaudeStepPrefix) || strings.HasPrefix(name, slackconnector.CodexStepPrefix)
}

func requireRow(res sql.Result, err error) error {
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil {
		return err
	} else if n == 0 {
		return ErrConversationGone
	}
	return nil
}

func requireMessageTx(tx *sql.Tx, id int64) error {
	var one int
	err := tx.QueryRow(`SELECT 1 FROM chat_messages WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrConversationGone
	}
	return err
}

// updateAssistantTx is ChatTreeQueries.updateAssistant, by message id.
func updateAssistantTx(tx *sql.Tx, id int64, text, status string, u *usage, f *Failure) error {
	var in, out sql.NullInt64
	if u != nil {
		in, out = sql.NullInt64{Int64: int64(u.in), Valid: true}, sql.NullInt64{Int64: int64(u.out), Valid: true}
	}
	var code, msg sql.NullString
	if f != nil {
		code, msg = sql.NullString{String: f.PersistenceCode(), Valid: true}, sql.NullString{String: f.Message, Valid: true}
	}
	res, err := tx.Exec(`UPDATE chat_messages SET text = ?, status = ?, tokens_in = ?, tokens_out = ?, error_code = ?, error_message = ?
		WHERE id = ?`, text, status, in, out, code, msg, id)
	return requireRow(res, err)
}

func setModelTx(tx *sql.Tx, id int64, u *usage) error {
	if u == nil || u.model == "" {
		return nil
	}
	_, err := tx.Exec(`UPDATE chat_messages SET model = ? WHERE id = ?`, u.model, id)
	return err
}

// markIfUsedTx is LiveSlackMark.markIfUsed, the finalize backstop.
func markIfUsedTx(tx *sql.Tx, conv, messageID int64) error {
	used, err := usedSlackConnector(tx, messageID)
	if err != nil || !used {
		return err
	}
	_, err = tx.Exec(`UPDATE chat_conversations SET live_slack_since = ? WHERE id = ? AND live_slack_since IS NULL`, messageID, conv)
	return err
}

func usedSlackConnector(tx *sql.Tx, messageID int64) (bool, error) {
	rows, err := tx.Query(`SELECT name FROM chat_turn_steps WHERE message_id = ?`, messageID)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	used := false
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return false, err
		}
		used = used || isSlackConnectorStep(name)
	}
	return used, rows.Err()
}

// saveArtifactVersionTx is ChatArtifactQueries.saveVersion for a non-edit
// save: the key's latest version is overwritten in place when this message
// produced it and the owner never edited it; anything else is MAX(version)+1.
func saveArtifactVersionTx(tx *sql.Tx, conv, messageID int64, a ParsedArtifact, createdAt float64) error {
	meta, err := metaJSON(a.Meta)
	if err != nil {
		return err
	}
	var latestID, latestMessage int64
	var edited bool
	err = tx.QueryRow(`SELECT id, message_id, edited FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ?
		ORDER BY version DESC LIMIT 1`, conv, a.Key).Scan(&latestID, &latestMessage, &edited)
	switch {
	case err == nil && latestMessage == messageID && !edited:
		_, err = tx.Exec(`UPDATE chat_artifacts SET kind = ?, title = ?, content = ?, meta_json = ? WHERE id = ?`,
			a.Kind, a.Title, a.Content, meta, latestID)
		return err
	case err != nil && !errors.Is(err, sql.ErrNoRows):
		return err
	}
	_, err = tx.Exec(`INSERT INTO chat_artifacts
		(conversation_id, message_id, artifact_key, version, kind, title, content, meta_json, edited, created_at)
		VALUES (?, ?, ?, (SELECT COALESCE(MAX(version), 0) + 1 FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ?),
			?, ?, ?, ?, 0, ?)`, conv, messageID, a.Key, conv, a.Key, a.Kind, a.Title, a.Content, meta, createdAt)
	return err
}

// titleIfNeeded calls the title hook after the conversation's first
// complete answer while it still has a prefix title (needsAITitle), once
// per conversation.
func (s *Store) titleIfNeeded(conv int64) {
	if s.title == nil {
		return
	}
	s.mu.Lock()
	asked := s.titled[conv]
	s.mu.Unlock()
	if asked {
		return
	}
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM chat_messages m JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE c.id = ? AND c.title_source = 'prefix' AND m.role = 'assistant' AND m.status = 'complete'`, conv).Scan(&n); err != nil || n != 1 {
		return // an unreadable count only skips the optional AI title, as on the Mac
	}
	s.mu.Lock()
	asked = s.titled[conv]
	s.titled[conv] = true
	s.mu.Unlock()
	if !asked {
		s.title(conv)
	}
}
