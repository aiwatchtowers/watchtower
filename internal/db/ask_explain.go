package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// AskExplainContextType is the chat_conversations.context_type of a "Not
// clear?" chat on an ask (spec 2026-11-24-ask-explain-chat): its context_id is
// `<workbench id>:<ask id>`. The chat explains one question to the owner and
// stays on that ask's panel, so it is never mined for knowledge, history or
// memory, goes with its workbench, and follows it on a merge.
const AskExplainContextType = "owner_ask_explain"

// AskExplainWorkbenchID is the workbench of an ask explain chat's context id
// `<workbench>:<ask>`; false when contextID is not of that form.
func AskExplainWorkbenchID(contextID string) (int64, bool) {
	wb, ask, ok := strings.Cut(contextID, ":")
	if !ok {
		return 0, false
	}
	id, err := strconv.ParseInt(wb, 10, 64)
	if err != nil || id <= 0 {
		return 0, false
	}
	if _, err := strconv.ParseInt(ask, 10, 64); err != nil {
		return 0, false
	}
	return id, true
}

// WorkbenchExistsTx reports whether workbench id still exists, read inside
// the caller's write transaction: a "Not clear?" chat is made only for a
// live workbench, so DeleteWorkbench (which drops the chats in its own
// transaction) and chat.new are serialised by the write lock and no chat of
// a deleted workbench is left behind (ask #1849, board #2383).
func WorkbenchExistsTx(tx *sql.Tx, id int64) (bool, error) {
	var one int
	err := tx.QueryRow(`SELECT 1 FROM projects WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading workbench %d: %w", id, err)
	}
	return true, nil
}

// askExplainDraftKeyTx maps a queued-draft surface key to the key its chat
// has now (ask #1849, board #2383). Only a "Not clear?" chat's key
// (`owner_ask_explain.<workbench>:<ask>.<conversation>`) is mapped; any
// other key comes back as is with keep true. For an explain key: its
// conversation deleted (the workbench went) → keep false, nothing is to be
// written; its conversation re-keyed by a workbench merge → the key under
// the surviving workbench, so a Mac engine still holding the old key writes
// and clears the draft the merge moved.
func askExplainDraftKeyTx(tx *sql.Tx, key string) (current string, keep bool, err error) {
	conversation, ok := askExplainDraftConversation(key)
	if !ok {
		return key, true, nil
	}
	var contextID string
	err = tx.QueryRow(`SELECT context_id FROM chat_conversations WHERE id = ? AND context_type = ?`,
		conversation, AskExplainContextType).Scan(&contextID)
	if errors.Is(err, sql.ErrNoRows) {
		return key, false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("reading the chat of queued draft %q: %w", key, err)
	}
	return AskExplainContextType + "." + contextID + "." + strconv.FormatInt(conversation, 10), true, nil
}

// askExplainDraftConversation is the conversation id at the end of an ask
// explain chat's surface key; false for any other key.
func askExplainDraftConversation(key string) (int64, bool) {
	rest, ok := strings.CutPrefix(key, AskExplainContextType+".")
	if !ok {
		return 0, false
	}
	dot := strings.LastIndex(rest, ".")
	if dot < 0 {
		return 0, false
	}
	id, err := strconv.ParseInt(rest[dot+1:], 10, 64)
	return id, err == nil
}
