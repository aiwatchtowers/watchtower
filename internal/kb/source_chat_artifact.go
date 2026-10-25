package kb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/html"
)

// chatArtifactSource renders the artifacts the owner kept from AI chats
// (chat_knowledge_artifacts): one document per (conversation, artifact key),
// showing the kept version only. A key is "chat_artifact:<conversation>:<key>".
type chatArtifactSource struct{}

func (chatArtifactSource) Name() string { return "chat_artifact" }

const chatArtifactPrefix = "chat_artifact:"

// keptJoin selects only rows whose kept version still exists, outside
// workbench code questions: a `code_question` conversation never surfaces
// outside its Questions tab (spec 2026-10-02 §9.4; the code-question guard in
// internal/tools pins this filter).
const keptJoin = `FROM chat_knowledge_artifacts k
	JOIN chat_artifacts a ON a.conversation_id = k.conversation_id
		AND a.artifact_key = k.artifact_key AND a.version = k.version
	JOIN chat_conversations c ON c.id = k.conversation_id
		AND COALESCE(c.context_type, '') != 'code_question'`

func (chatArtifactSource) Changed(ctx context.Context, q Queryer, cursor string, _ time.Time) ([]string, string, bool, error) {
	keys, next, err := changedByColumn(ctx, q, cursor,
		`SELECT 'chat_artifact:' || k.conversation_id || ':' || k.artifact_key, k.kept_at `+keptJoin+` WHERE k.kept_at >= ?`,
		cursor)
	return keys, next, true, err
}

func (chatArtifactSource) Keys(ctx context.Context, q Queryer) ([]string, error) {
	return queryStrings(ctx, q, `SELECT 'chat_artifact:' || k.conversation_id || ':' || k.artifact_key `+keptJoin)
}

func (chatArtifactSource) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	rest, ok := splitRef(key, chatArtifactPrefix)
	if !ok {
		return nil, nil
	}
	convStr, artKey, ok := strings.Cut(rest, ":")
	conv, convErr := strconv.ParseInt(convStr, 10, 64)
	if !ok || convErr != nil {
		return nil, nil //nolint:nilerr // a malformed ref is a missing doc, not an error
	}
	var kind, title, content, convTitle, keptAt string
	err := q.QueryRowContext(ctx, `SELECT a.kind, a.title, a.content, c.title, k.kept_at `+keptJoin+`
		WHERE k.conversation_id = ? AND k.artifact_key = ?`, conv, artKey).
		Scan(&kind, &title, &content, &convTitle, &keptAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("kb chat artifact %s: %w", key, err)
	}
	if kind == "html" {
		content = htmlToText(content)
	}
	doc := &Doc{
		ID:     key,
		Source: "chat_artifact",
		Title:  title,
		Meta:   strings.TrimSpace(convTitle + " " + kind),
		Time:   parseTime(keptAt),
		Anchor: map[string]string{"conversation_id": convStr, "artifact_key": artKey},
	}
	for _, line := range strings.Split(content, "\n") {
		if strings.TrimSpace(line) != "" {
			doc.Sections = append(doc.Sections, Section{Text: line})
		}
	}
	return doc, nil
}

// htmlToText reduces an HTML artifact to its visible text, one line per
// block: tags dropped, script/style/head content skipped. (internal/extract
// has a fuller stripper, but extsync's tests import kb, so kb cannot import it.)
func htmlToText(doc string) string {
	z := html.NewTokenizer(strings.NewReader(doc))
	var b strings.Builder
	skip := 0
	for {
		tt := z.Next()
		if tt == html.ErrorToken {
			return b.String()
		}
		if tt == html.TextToken {
			if skip == 0 {
				b.Write(z.Text())
			}
			continue
		}
		if tt != html.StartTagToken && tt != html.EndTagToken && tt != html.SelfClosingTagToken {
			continue
		}
		name, _ := z.TagName()
		switch string(name) {
		case "body":
			// Whatever hid text before <body> (a never-closed <head>) ends
			// here, as it does in a browser.
			if tt == html.StartTagToken {
				skip = 0
			}
		case "script", "style", "head", "template":
			if tt == html.StartTagToken {
				skip++
			} else if tt == html.EndTagToken && skip > 0 {
				skip--
			}
		case "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "table", "pre":
			b.WriteByte('\n')
		case "td", "th":
			b.WriteString(" | ")
		}
	}
}
