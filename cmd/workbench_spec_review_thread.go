package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/specreview"
	"watchtower/internal/sqlcipher"
)

// maxQuestionRunes caps a thread's question to the author (stdin, trimmed).
const maxQuestionRunes = 1000

var workbenchSpecReviewQuestionCmd = &cobra.Command{
	Use:   "question --ask N --item K | --close ID --reason gone",
	Short: "File a thread's question to the author of ask N, or close one",
	Long: "With --ask and --item, files the question on stdin (trimmed, at most 1000 characters) in the\n" +
		"thread of item K along ask N's review chain and prints its id; exit 3 when the thread already\n" +
		"has an open question or the ask has no session. With --close ID --reason gone, closes an open\n" +
		"question the Desktop could not deliver; exit 3 \"the question is closed\" when it is not open.",
	Args: cobra.NoArgs,
	RunE: runSpecReviewQuestion,
}

var (
	specReviewQuestionFlagAsk    int64
	specReviewQuestionFlagItem   string
	specReviewQuestionFlagClose  int64
	specReviewQuestionFlagReason string
)

func init() {
	f := workbenchSpecReviewQuestionCmd.Flags()
	f.Int64Var(&specReviewQuestionFlagAsk, "ask", 0, "owner ask id")
	f.StringVar(&specReviewQuestionFlagItem, "item", "", "the item key of the thread (a finding or a thesis)")
	f.Int64Var(&specReviewQuestionFlagClose, "close", 0, "question id to close")
	f.StringVar(&specReviewQuestionFlagReason, "reason", "", "why the question closes (gone)")
	workbenchSpecReviewCmd.AddCommand(workbenchSpecReviewQuestionCmd)

	f = workbenchSpecReviewAddFindingCmd.Flags()
	f.Int64Var(&specReviewAddFindingFlagAsk, "ask", 0, "owner ask id")
	f.StringVar(&specReviewAddFindingFlagThread, "thread", "", "the thread's conversation key (<workbench>:<root ask>:<item key>)")
	_ = workbenchSpecReviewAddFindingCmd.MarkFlagRequired("ask")
	_ = workbenchSpecReviewAddFindingCmd.MarkFlagRequired("thread")
	workbenchSpecReviewCmd.AddCommand(workbenchSpecReviewAddFindingCmd)

	f = workbenchSpecReviewThreadContextCmd.Flags()
	f.Int64Var(&specReviewThreadContextFlagAsk, "ask", 0, "owner ask id")
	f.StringVar(&specReviewThreadContextFlagItem, "item", "", "the item key of the thread")
	f.BoolVar(&specReviewThreadContextFlagDir, "folder-only", false, "print only the folder the reviewer read")
	_ = workbenchSpecReviewThreadContextCmd.MarkFlagRequired("ask")
	_ = workbenchSpecReviewThreadContextCmd.MarkFlagRequired("item")
	workbenchSpecReviewCmd.AddCommand(workbenchSpecReviewThreadContextCmd)
}

func runSpecReviewQuestion(cmd *cobra.Command, _ []string) error {
	closing := cmd.Flags().Changed("close")
	var question string
	switch {
	case closing:
		if cmd.Flags().Changed("ask") || cmd.Flags().Changed("item") {
			return usageError("--close takes no --ask or --item")
		}
		if specReviewQuestionFlagReason != "gone" {
			return usageError("--close needs --reason gone")
		}
	case specReviewQuestionFlagAsk <= 0 || strings.TrimSpace(specReviewQuestionFlagItem) == "":
		return usageError("give --ask N --item K, or --close ID --reason gone")
	case cmd.Flags().Changed("reason"):
		return usageError("--reason goes with --close")
	default:
		q, err := readSpecReviewQuestion(cmd.InOrStdin())
		if err != nil {
			return err
		}
		question = q
	}

	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	now := time.Now()
	if closing {
		id := specReviewQuestionFlagClose
		if err := database.CloseSpecReviewQuestion(id, "gone", now); err != nil {
			if errors.Is(err, db.ErrQuestionClosed) {
				return &exitCodeError{code: 3, err: fmt.Errorf("question %d: %w", id, err)}
			}
			return fmt.Errorf("closing question %d: %w", id, err)
		}
		fmt.Fprintf(cmd.OutOrStdout(), "question %d closed\n", id)
		return nil
	}

	id, item := specReviewQuestionFlagAsk, strings.TrimSpace(specReviewQuestionFlagItem)
	ask, err := database.GetOwnerAskByID(id)
	if err != nil {
		return fmt.Errorf("loading ask %d: %w", id, err)
	}
	if t := specreview.DocType(ask.DocType); ask.Kind != "review" || (t != specreview.Spec && t != specreview.Plan) {
		return usageError("ask %d is not a spec or plan review", id)
	}
	if !ask.SessionID.Valid {
		return &exitCodeError{code: 3, err: fmt.Errorf("ask %d has no session", id)}
	}
	chain, err := database.SpecReviewChain(id)
	if err != nil {
		return fmt.Errorf("reading the review chain of ask %d: %w", id, err)
	}
	if len(chain) == 0 {
		return fmt.Errorf("ask %d has no review chain", id)
	}
	thread := specreview.ThreadContextID(ask.WorkbenchID, chain[0], item)
	qid, err := database.FileSpecReviewQuestion(id, thread, item, question, now)
	if err != nil {
		if errors.Is(err, db.ErrQuestionOpen) {
			return &exitCodeError{code: 3, err: errors.New("a question is already open in this thread")}
		}
		return fmt.Errorf("filing the question on ask %d: %w", id, err)
	}
	fmt.Fprintln(cmd.OutOrStdout(), qid)
	return nil
}

// readSpecReviewQuestion reads the question from stdin, trimmed: empty or
// longer than maxQuestionRunes is a usage error.
func readSpecReviewQuestion(r io.Reader) (string, error) {
	// Enough bytes for maxQuestionRunes of any width plus one, so a longer
	// question is seen as longer without reading an unbounded stdin.
	data, err := io.ReadAll(io.LimitReader(r, int64(maxQuestionRunes*utf8.UTFMax+1)))
	if err != nil {
		return "", fmt.Errorf("reading the question: %w", err)
	}
	q := strings.TrimSpace(string(data))
	switch {
	case q == "":
		return "", usageError("the question on stdin is empty")
	case utf8.RuneCountInString(q) > maxQuestionRunes || len(data) > maxQuestionRunes*utf8.UTFMax:
		return "", usageError("the question is longer than %d characters", maxQuestionRunes)
	}
	return q, nil
}

// maxFindingBlockBytes caps the finding block read from stdin.
const maxFindingBlockBytes = 64 << 10

var workbenchSpecReviewAddFindingCmd = &cobra.Command{
	Use:   "add-finding --ask N --thread CONTEXT_ID",
	Short: "Add a finding a Discuss thread proposed to ask N's review",
	Long: "Reads the thread agent's finding block (JSON) on stdin, checks its quotes against ask N's\n" +
		"document snapshot and the owner's own rows of the thread, stores it and prints {\"key\": \"tf:…\"}.\n" +
		"Adding the same finding again prints its key. Exit 3 with the refusal text: \"not added: quote not\n" +
		"found\", another refusal of the block, or a thread that is not part of ask N's review chain.",
	Args: cobra.NoArgs,
	RunE: runSpecReviewAddFinding,
}

var workbenchSpecReviewThreadContextCmd = &cobra.Command{
	Use:   "thread-context --ask N --item K [--folder-only]",
	Short: "Print the Discuss thread agent's context for item K of ask N's review",
	Long: "Prints, as fenced data blocks, the document snapshot, the item with its quotes, the whole\n" +
		"stored result, the ledger, the author's replies and the conversation and asks blocks the\n" +
		"reviewer was given. The database is opened read-only. Exit 3 \"no such item\" for an unknown key.\n" +
		"With --folder-only, prints only \"read_folder: <dir>\": the folder the reviewer read (the session's\n" +
		"recorded working directory, else the workbench folder), for the thread's ai query --read-folder.",
	Args: cobra.NoArgs,
	RunE: runSpecReviewThreadContext,
}

var (
	specReviewAddFindingFlagAsk     int64
	specReviewAddFindingFlagThread  string
	specReviewThreadContextFlagAsk  int64
	specReviewThreadContextFlagItem string
	specReviewThreadContextFlagDir  bool
)

// specReviewContextFeed reads a session's chat for thread-context; tests swap it.
var specReviewContextFeed = specReviewFeed

func runSpecReviewAddFinding(cmd *cobra.Command, _ []string) error {
	id, thread := specReviewAddFindingFlagAsk, strings.TrimSpace(specReviewAddFindingFlagThread)
	wbID, rootID, _, ok := specreview.ParseThreadContextID(thread)
	if !ok {
		return usageError("--thread %q is not a thread key", thread)
	}
	data, err := io.ReadAll(io.LimitReader(cmd.InOrStdin(), maxFindingBlockBytes+1))
	if err != nil {
		return fmt.Errorf("reading the finding: %w", err)
	}
	if len(data) > maxFindingBlockBytes {
		return &exitCodeError{code: 3, err: errors.New("not added: the finding is too long")}
	}
	var in specreview.ThreadFindingInput
	if err := json.Unmarshal(data, &in); err != nil {
		return &exitCodeError{code: 3, err: errors.New("not added: the finding is not valid JSON")}
	}

	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	ask, err := database.GetOwnerAskByID(id)
	if err != nil {
		return fmt.Errorf("loading ask %d: %w", id, err)
	}
	t := specreview.DocType(ask.DocType)
	if ask.Kind != "review" || (t != specreview.Spec && t != specreview.Plan) {
		return usageError("ask %d is not a spec or plan review", id)
	}
	chain, err := database.SpecReviewChain(id)
	if err != nil {
		return fmt.Errorf("reading the review chain of ask %d: %w", id, err)
	}
	if wbID != ask.WorkbenchID || len(chain) == 0 || rootID != chain[0] {
		return &exitCodeError{code: 3, err: fmt.Errorf("this thread is not part of ask %d's review", id)}
	}
	owner, err := database.OwnerThreadLines(thread)
	if err != nil {
		return err
	}
	f, err := specreview.ValidateThreadFinding(in, ask.DocSnapshot, t, owner)
	if err != nil {
		return &exitCodeError{code: 3, err: err}
	}
	f.Thread = thread
	js, err := json.Marshal(f)
	if err != nil {
		return fmt.Errorf("encoding the finding: %w", err)
	}
	err = database.InsertSpecReviewThreadFinding(db.SpecReviewThreadFinding{
		AskID: id, ItemKey: f.Key, Thread: thread, Finding: string(js),
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
	})
	// The same finding pressed twice: its key is already stored.
	var se sqlcipher.Error
	if err != nil && !(errors.As(err, &se) && se.ExtendedCode == sqlcipher.ErrConstraintPrimaryKey) {
		return err
	}
	return writeJSON(cmd.OutOrStdout(), map[string]string{"key": f.Key})
}

func runSpecReviewThreadContext(cmd *cobra.Command, _ []string) error {
	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	database, err := db.OpenExisting(cfg.DBPath(), sessionFeedBusyTimeout)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	id, item := specReviewThreadContextFlagAsk, strings.TrimSpace(specReviewThreadContextFlagItem)
	if specReviewThreadContextFlagDir {
		ask, err := database.GetOwnerAskByID(id)
		if err != nil {
			return fmt.Errorf("loading ask %d: %w", id, err)
		}
		dir, err := specreview.ReadFolder(database, ask)
		if err != nil {
			return fmt.Errorf("the folder of ask %d: %w", id, err)
		}
		_, err = fmt.Fprintf(cmd.OutOrStdout(), "read_folder: %s\n", dir)
		return err
	}
	out, err := specreview.ThreadContext(ctx, specreview.Deps{DB: database, Feed: specReviewContextFeed(database)}, id, item)
	if errors.Is(err, specreview.ErrNoSuchItem) || errors.Is(err, db.ErrSpecReviewNotFound) {
		return &exitCodeError{code: 3, err: fmt.Errorf("ask %d: no such item %s", id, item)}
	}
	if err != nil {
		return err
	}
	_, err = io.WriteString(cmd.OutOrStdout(), out)
	return err
}
