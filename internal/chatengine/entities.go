package chatengine

import (
	"context"
	"database/sql"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"unicode"

	"github.com/rivo/uniseg"

	"watchtower/internal/chatstore"
	"watchtower/internal/db"
	"watchtower/internal/skills"
)

// EntityHit is one local entity a picker offers (Swift ChatEntityHit): Kind
// is person, channel, jira, linear, jira_project, confluence_space, target
// or track; ID the ref the model's get_* tools take.
type EntityHit struct {
	Kind   string `json:"kind"`
	ID     string `json:"id"`
	Label  string `json:"label"`
	Detail string `json:"detail"`
}

// The picker sizes: the `@` picker's (MentionSearch.resultLimit) and the
// project source picker's (ProjectSourcePickerSheet).
const (
	MentionLimit = 8
	PickerLimit  = 30
)

// entityKinds is Swift ChatEntityKind.
var entityKinds = []string{"person", "channel", "jira", "linear", "jira_project", "confluence_space", "target", "track"}

// mentionSearchKinds is MentionSearch's kind order.
var mentionSearchKinds = []string{"person", "jira", "channel", "target", "track"}

// EntitySearch is the pickers' prefix search over the local database. With
// no kinds it is the `@` picker (Swift MentionSearch.search): people, issues,
// channels, targets and tracks, label-prefix hits first, at most
// MentionLimit. With kinds it is ChatEntitySearch.search of each kind in
// order, PickerLimit each (the project source picker). An unknown kind is
// ErrInvalid. testdata/entity_search_cases.json pins it to Swift.
func (e *Engine) EntitySearch(ctx context.Context, q string, kinds []string) ([]EntityHit, error) {
	return searchEntities(ctx, e.c.Read, q, kinds)
}

func searchEntities(ctx context.Context, d *db.DB, q string, kinds []string) ([]EntityHit, error) {
	for _, k := range kinds {
		if !slices.Contains(entityKinds, k) {
			return nil, chatstore.ErrInvalid
		}
	}
	if len(kinds) > 0 {
		var out []EntityHit
		for _, k := range kinds {
			hits, err := searchKind(ctx, d, k, q, PickerLimit)
			if err != nil {
				return nil, err
			}
			out = append(out, hits...)
		}
		return out, nil
	}
	var hits []EntityHit
	for _, k := range mentionSearchKinds {
		h, err := searchKind(ctx, d, k, q, MentionLimit)
		if err != nil {
			return nil, err
		}
		hits = append(hits, h...)
	}
	for i := range hits {
		hits[i].Label = mentionLabel(hits[i].Label)
	}
	needle := strings.ToLower(trimSwiftSpaces(q))
	slices.SortStableFunc(hits, func(a, b EntityHit) int {
		return labelRank(a, needle) - labelRank(b, needle)
	})
	if len(hits) > MentionLimit {
		hits = hits[:MentionLimit]
	}
	return hits, nil
}

// labelRank is MentionSearch.labelMatches as a sort key (0 first).
func labelRank(h EntityHit, needle string) int {
	if needle == "" || strings.HasPrefix(strings.ToLower(strings.TrimPrefix(h.Label, "#")), needle) {
		return 0
	}
	return 1
}

// mentionLabel is MentionCandidate's label: one line.
func mentionLabel(s string) string {
	return strings.NewReplacer("\r\n", " ", "\n", " ", "\r", " ").Replace(s)
}

func searchKind(ctx context.Context, d *db.DB, kind, q string, limit int) ([]EntityHit, error) {
	switch kind {
	case "person":
		return searchPeople(ctx, d, q, limit)
	case "channel":
		return searchChannels(ctx, d, q, limit)
	case "jira":
		return searchIssues(ctx, d, q, limit, "")
	case "linear":
		return searchIssues(ctx, d, q, limit, "linear")
	case "jira_project":
		return searchJiraProjects(ctx, d, q, limit)
	case "confluence_space":
		return searchSpaces(ctx, d, q, limit)
	case "target":
		return searchTargets(ctx, d, q, limit)
	default:
		return searchTracks(ctx, d, q, limit)
	}
}

// queryHits runs query and scans each row with scan.
func queryHits(ctx context.Context, d *db.DB, query string, args []any, scan func(*sql.Rows) (EntityHit, error)) ([]EntityHit, error) {
	rs, err := d.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("chatengine: entity search: %w", err)
	}
	defer rs.Close()
	var out []EntityHit
	for rs.Next() {
		h, err := scan(rs)
		if err != nil {
			return nil, fmt.Errorf("chatengine: entity search: %w", err)
		}
		out = append(out, h)
	}
	if err := rs.Err(); err != nil {
		return nil, fmt.Errorf("chatengine: entity search: %w", err)
	}
	return out, nil
}

func searchPeople(ctx context.Context, d *db.DB, q string, limit int) ([]EntityHit, error) {
	where, args := prefixClause(q, "name", "display_name", "real_name")
	return queryHits(ctx, d, `SELECT id, name, COALESCE(NULLIF(display_name, ''), NULLIF(real_name, ''), name) AS label
		FROM users WHERE is_bot = 0 AND is_deleted = 0 AND is_stub = 0 AND `+where+`
		ORDER BY label COLLATE NOCASE, id LIMIT ?`, append(args, limit), func(r *sql.Rows) (EntityHit, error) {
		h := EntityHit{Kind: "person"}
		var name string
		err := r.Scan(&h.ID, &name, &h.Label)
		h.Detail = "@" + name
		return h, err
	})
}

func searchChannels(ctx context.Context, d *db.DB, q string, limit int) ([]EntityHit, error) {
	where, args := prefixClause(q, "name")
	return queryHits(ctx, d, `SELECT id, name FROM channels
		WHERE type IN ('public', 'private') AND is_archived = 0 AND `+where+`
		ORDER BY is_member DESC, name COLLATE NOCASE, id LIMIT ?`, append(args, limit), func(r *sql.Rows) (EntityHit, error) {
		h := EntityHit{Kind: "channel", Detail: "Slack channel"}
		var name string
		err := r.Scan(&h.ID, &name)
		h.Label = "#" + name
		return h, err
	})
}

// searchIssues is ChatEntitySearch.issues: tracker_issues by key prefix or
// title word prefix, one hit per (tracker, key); tracker "" = both.
func searchIssues(ctx context.Context, d *db.DB, q string, limit int, tracker string) ([]EntityHit, error) {
	title, targs := prefixClause(q, "title")
	args := append([]any{likeEscape(strings.ToUpper(trimSwiftSpaces(q))) + "%"}, targs...)
	filter := ""
	if tracker != "" {
		filter = " AND tracker = ?"
		args = append(args, tracker)
	}
	return queryHits(ctx, d, `SELECT tracker, key, title, MAX(updated_at) AS newest FROM tracker_issues
		WHERE is_deleted = 0 AND (key LIKE ? ESCAPE '\' OR `+title+`)`+filter+`
		GROUP BY tracker, key ORDER BY newest DESC, key, tracker LIMIT ?`, append(args, limit), func(r *sql.Rows) (EntityHit, error) {
		var tr string
		var newest sql.NullString
		h := EntityHit{Kind: "jira"}
		err := r.Scan(&tr, &h.ID, &h.Detail, &newest)
		if tr == "linear" {
			h.Kind = "linear"
		}
		h.Label = h.ID
		return h, err
	})
}

func searchJiraProjects(ctx context.Context, d *db.DB, q string, limit int) ([]EntityHit, error) {
	pattern := likeEscape(strings.ToUpper(trimSwiftSpaces(q))) + "%"
	return queryHits(ctx, d, `SELECT project_key, COUNT(DISTINCT key) AS n FROM jira_issues
		WHERE is_deleted = 0 AND project_key LIKE ? ESCAPE '\'
		GROUP BY project_key ORDER BY project_key LIMIT ?`, []any{pattern, limit}, func(r *sql.Rows) (EntityHit, error) {
		h := EntityHit{Kind: "jira_project"}
		var n int
		err := r.Scan(&h.ID, &n)
		h.Label = h.ID
		h.Detail = strconv.Itoa(n) + " issues"
		if n == 1 {
			h.Detail = "1 issue"
		}
		return h, err
	})
}

func searchSpaces(ctx context.Context, d *db.DB, q string, limit int) ([]EntityHit, error) {
	name, nargs := prefixClause(q, "container_name")
	args := append([]any{likeEscape(strings.ToUpper(trimSwiftSpaces(q))) + "%"}, nargs...)
	return queryHits(ctx, d, `SELECT upper(container_key) AS space_key, MAX(container_name) AS name FROM ext_sources
		WHERE provider = 'confluence' AND enabled = 1 AND (upper(container_key) LIKE ? ESCAPE '\' OR `+name+`)
		GROUP BY upper(container_key) ORDER BY space_key LIMIT ?`, append(args, limit), func(r *sql.Rows) (EntityHit, error) {
		h := EntityHit{Kind: "confluence_space"}
		var n string
		err := r.Scan(&h.ID, &n)
		h.Label = n
		if n == "" {
			h.Label = h.ID
		}
		h.Detail = "Confluence space " + h.ID
		return h, err
	})
}

func searchTargets(ctx context.Context, d *db.DB, q string, limit int) ([]EntityHit, error) {
	where, args := prefixClause(q, "text")
	return queryHits(ctx, d, `SELECT id, text, status FROM targets
		WHERE project_id IS NULL AND status NOT IN ('done', 'dismissed') AND `+where+`
		ORDER BY updated_at DESC, id DESC LIMIT ?`, append(args, limit), func(r *sql.Rows) (EntityHit, error) {
		h := EntityHit{Kind: "target"}
		var id int64
		var text string
		err := r.Scan(&id, &text, &h.Detail)
		h.ID, h.Label = strconv.FormatInt(id, 10), firstLine(text)
		return h, err
	})
}

func searchTracks(ctx context.Context, d *db.DB, q string, limit int) ([]EntityHit, error) {
	where, args := prefixClause(q, "text")
	return queryHits(ctx, d, `SELECT id, text, priority FROM tracks
		WHERE dismissed_at = '' AND `+where+`
		ORDER BY updated_at DESC, id DESC LIMIT ?`, append(args, limit), func(r *sql.Rows) (EntityHit, error) {
		h := EntityHit{Kind: "track"}
		var id int64
		var text, priority string
		err := r.Scan(&id, &text, &priority)
		h.ID, h.Label, h.Detail = strconv.FormatInt(id, 10), firstLine(text), "track · "+priority
		return h, err
	})
}

// prefixClause is Swift PrefixMatch(q).clause(columns:): each column LIKE
// the query (and its first letter upper- and lower-cased, since LIKE folds
// ASCII only) as a prefix or a word prefix; "1" for an empty query.
func prefixClause(q string, columns ...string) (string, []any) {
	query := trimSwiftSpaces(q)
	if query == "" {
		return "1", nil
	}
	first, rest := query, ""
	if g := uniseg.NewGraphemes(query); g.Next() {
		_, end := g.Positions()
		first, rest = query[:end], query[end:]
	}
	variants := []string{query}
	for _, v := range []string{strings.ToUpper(first) + rest, strings.ToLower(first) + rest} {
		if !slices.Contains(variants, v) {
			variants = append(variants, v)
		}
	}
	var patterns []string
	for _, v := range variants {
		esc := likeEscape(v)
		patterns = append(patterns, esc+"%", "% "+esc+"%")
	}
	var parts []string
	var args []any
	for _, c := range columns {
		for _, p := range patterns {
			parts = append(parts, c+` LIKE ? ESCAPE '\'`)
			args = append(args, p)
		}
	}
	return "(" + strings.Join(parts, " OR ") + ")", args
}

// likeEscape is PrefixMatch.escape.
func likeEscape(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}

// trimSwiftSpaces is trimmingCharacters(in: .whitespaces): no newlines.
func trimSwiftSpaces(s string) string {
	return strings.TrimFunc(s, func(r rune) bool { return r == '\t' || unicode.Is(unicode.Zs, r) })
}

// firstLine is ChatEntitySearch.firstLine: the first non-empty line,
// trimmed, at most 60 characters (59 and "…" when longer).
func firstLine(text string) string {
	line := ""
	for _, l := range strings.FieldsFunc(text, isNewlineRune) {
		line = l
		break
	}
	line = trimSwiftSpaces(line)
	if uniseg.GraphemeClusterCount(line) <= 60 {
		return line
	}
	var b strings.Builder
	g := uniseg.NewGraphemes(line)
	for i := 0; i < 59 && g.Next(); i++ {
		b.WriteString(g.Str())
	}
	return b.String() + "…"
}

// isNewlineRune is Character.isNewline per scalar.
func isNewlineRune(r rune) bool {
	switch r {
	case '\n', '\r', '\v', '\f', 0x85, 0x2028, 0x2029:
		return true
	}
	return false
}

// SkillSummary is one skill the `/` picker offers.
type SkillSummary struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

// SkillsList is the `/` picker's catalog (SkillsCatalog.pickerSkills for the
// main chat): the workspace's enabled skills, by name. No SkillsDir, or no
// folder, is an empty catalog.
func (e *Engine) SkillsList(_ context.Context) ([]SkillSummary, error) {
	out := []SkillSummary{}
	if e.c.SkillsDir == "" {
		return out, nil
	}
	list, err := skills.List(e.c.SkillsDir)
	if err != nil {
		return nil, fmt.Errorf("chatengine: reading skills: %w", err)
	}
	for _, s := range list {
		if s.Enabled {
			out = append(out, SkillSummary{Name: s.Name, Description: s.Description})
		}
	}
	return out, nil
}
