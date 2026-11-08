package cmd

import (
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/specreview"
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
