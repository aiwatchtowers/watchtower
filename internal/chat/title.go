package chat

import (
	"context"
	"fmt"
	"strings"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

const (
	// TitleMaxRunes caps a generated chat title.
	TitleMaxRunes     = 60
	titleExcerptRunes = 4000
)

// TitleResult is what GenerateTitle did: the title it wrote (or the owner's,
// untouched), whether it was written, and the prompt fallback it took, if any
// (the caller reports it; the default prompt was used).
type TitleResult struct {
	Title          string
	Written        bool
	PromptFallback error
}

// GenerateTitle names conversation conv from its first exchange with gen
// (the light-tier generator) and stores the title with title_source='ai'. A
// title the owner set (title_source='user') is never overwritten: it is
// returned with Written false and no AI call is made; an owner rename that
// lands between the read and the write still wins (SetChatTitle's guard).
// The AI call runs outside any transaction. `watchtower chat title` and the
// hub's chat turn store both call it.
func GenerateTitle(ctx context.Context, d *db.DB, cfg *config.Config, gen digest.Generator, conv int64) (TitleResult, error) {
	c, err := d.GetChatConversation(conv)
	if err != nil {
		return TitleResult{}, err
	}
	if c == nil {
		return TitleResult{}, fmt.Errorf("conversation %d not found", conv)
	}
	if c.TitleSource == "user" {
		return TitleResult{Title: c.Title}, nil
	}
	path, err := d.ActiveChatPath(conv)
	if err != nil {
		return TitleResult{}, err
	}
	owner, assistant := firstChatExchange(path)
	if owner == "" {
		return TitleResult{}, fmt.Errorf("conversation %d has no owner message yet", conv)
	}
	system, user, promptErr := titlePrompt(d, cfg, owner, assistant)
	reply, _, _, err := gen.Generate(digest.WithSource(ctx, "chat.title"), system, user, "")
	if err != nil {
		return TitleResult{PromptFallback: promptErr}, fmt.Errorf("generating the title: %w", err)
	}
	title := CleanTitle(reply)
	if title == "" {
		return TitleResult{PromptFallback: promptErr}, fmt.Errorf("the model returned an empty title")
	}
	written, err := d.SetChatTitle(conv, title, "ai")
	if err != nil {
		return TitleResult{PromptFallback: promptErr}, err
	}
	return TitleResult{Title: title, Written: written, PromptFallback: promptErr}, nil
}

// titlePrompt renders the chat.title system prompt (the tunable DB row, else
// the registered default, reported as fallback) and the first-exchange user
// message.
func titlePrompt(d *db.DB, cfg *config.Config, owner, assistant string) (system, user string, fallback error) {
	tmpl, _, err := prompts.Resolve(prompts.New(d, nil), prompts.ChatTitle, "")
	system = fmt.Sprintf(tmpl, prompts.Directive(cfg.Digest.Language))
	user = "=== FIRST EXCHANGE ===\nOwner: " + excerptRunes(owner, titleExcerptRunes) +
		"\n\nAssistant: " + excerptRunes(assistant, titleExcerptRunes)
	return system, user, err
}

// firstChatExchange returns the first owner message and the first assistant
// reply after it on the active path.
func firstChatExchange(path []db.ChatMessage) (owner, assistant string) {
	for _, m := range path {
		switch {
		case m.Role == "user" && owner == "":
			owner = strings.TrimSpace(m.Text)
		case m.Role == "assistant" && owner != "" && assistant == "":
			assistant = strings.TrimSpace(m.Text)
		}
	}
	return owner, assistant
}

// CleanTitle takes the first non-empty line of the reply and strips the
// decoration models add anyway: heading/list markers, a "Title:" label,
// quotes of any script, emphasis and a trailing period; then caps it at
// TitleMaxRunes runes.
func CleanTitle(reply string) string {
	s := TitleLine(reply)
	if r := []rune(s); len(r) > TitleMaxRunes {
		s = strings.TrimSpace(string(r[:TitleMaxRunes-1])) + "…"
	}
	return s
}

// TitleLine is the reply's first line that still has text once markdown
// markers, a "Title:" prefix, quotes and a trailing period are stripped;
// not yet capped at TitleMaxRunes.
func TitleLine(reply string) string {
	for line := range strings.SplitSeq(reply, "\n") {
		s := strings.TrimSpace(line)
		s = strings.TrimLeft(s, "#>-* ")
		if strings.HasPrefix(strings.ToLower(s), "title:") {
			s = strings.TrimSpace(s[len("title:"):])
		}
		s = strings.Trim(s, "\"'`“”«»*_ ")
		s = strings.TrimSpace(strings.TrimSuffix(s, "."))
		if s != "" {
			return s
		}
	}
	return ""
}

// excerptRunes caps s at n runes (the first exchange can be a pasted document).
func excerptRunes(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}
