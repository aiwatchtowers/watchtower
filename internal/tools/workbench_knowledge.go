package tools

import (
	"context"
	"fmt"
	"net/url"
	"regexp"
	"slices"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/kb"
)

// jiraProjectKey is a Jira project key once upper-cased (the shape
// internal/jira's sync accepts).
var jiraProjectKey = regexp.MustCompile(`^[A-Z][A-Z0-9_]+$`)

// scopeSource is one pinned source as the scope resolution sees it: the
// workbench's project_sources row or a chat project's chat_project_sources
// row (the two tables share the kind and ref vocabulary).
type scopeSource struct{ Kind, Ref string }

// WorkbenchKnowledgeScope turns the project's slack_channel, jira_project and
// confluence_space sources into the kb.Scope its search and brief prefer
// (resolution rules: knowledgeScope).
func WorkbenchKnowledgeScope(ctx context.Context, d *db.DB, projectID int64) (kb.Scope, []string, error) {
	sources, err := d.ListWorkbenchSources(projectID)
	if err != nil {
		return kb.Scope{}, nil, fmt.Errorf("listing workbench sources: %w", err)
	}
	refs := make([]scopeSource, len(sources))
	for i, src := range sources {
		refs[i] = scopeSource{Kind: src.Kind, Ref: src.Ref}
	}
	return knowledgeScope(ctx, d, refs)
}

// chatProjectKnowledgeScope is WorkbenchKnowledgeScope for a chat project's
// pinned sources: the same kinds steer search the same way, the rest
// (target, track, person) stay prompt-only. A chat project that does not
// exist (deleted mid-session) has no sources, so an empty scope.
func chatProjectKnowledgeScope(ctx context.Context, d *db.DB, chatProjectID int64) (kb.Scope, []string, error) {
	sources, err := d.ChatProjectSources(chatProjectID)
	if err != nil {
		return kb.Scope{}, nil, fmt.Errorf("listing chat project sources: %w", err)
	}
	refs := make([]scopeSource, len(sources))
	for i, src := range sources {
		refs[i] = scopeSource{Kind: src.Kind, Ref: src.Ref}
	}
	return knowledgeScope(ctx, d, refs)
}

// ScopedSourceKinds are the source kinds knowledgeScope resolves; every other
// kind (person, link, target, track) is informational only. The chat prompt
// names them to the model.
var ScopedSourceKinds = []string{"slack_channel", "jira_project", "confluence_space"}

// knowledgeScope turns slack_channel, jira_project and confluence_space
// sources (ScopedSourceKinds) into a kb.Scope. Mechanical: a Slack ref (an id with or without the
// account prefix, a #name or a channel URL) resolves against the synced
// channels — every account's channel of that name or id, none when nothing
// matches; a Jira ref is a project key, an issue key or a browse/projects
// URL; a Confluence ref is a space key or a /spaces/KEY or /display/KEY URL.
// A ref that resolves to nothing is skipped, never an error — a source is
// informational, not a filter — and returned in unresolved so the caller can
// say so.
func knowledgeScope(ctx context.Context, d *db.DB, sources []scopeSource) (s kb.Scope, unresolved []string, err error) {
	for _, src := range sources {
		var found []string
		switch src.Kind {
		case "slack_channel":
			if found, err = slackChannelIDs(ctx, d, src.Ref); err != nil {
				return kb.Scope{}, nil, err
			}
			s.SlackChannels = appendNew(s.SlackChannels, found...)
		case "jira_project":
			found = nonEmpty(jiraProjectRef(src.Ref))
			s.JiraProjects = appendNew(s.JiraProjects, found...)
		case "confluence_space":
			found = nonEmpty(confluenceSpaceRef(src.Ref))
			s.ConfluenceSpaces = appendNew(s.ConfluenceSpaces, found...)
		default:
			continue // person, link, target, track: never part of the search scope
		}
		if len(found) == 0 {
			unresolved = append(unresolved, src.Kind+" "+src.Ref)
		}
	}
	return s, unresolved, nil
}

func nonEmpty(v string) []string {
	if v == "" {
		return nil
	}
	return []string{v}
}

func appendNew(list []string, values ...string) []string {
	for _, v := range values {
		if !slices.Contains(list, v) {
			list = append(list, v)
		}
	}
	return list
}

// urlSegmentAfter returns the path segment following marker in ref ("" when
// ref has no marker), cut at the next '/', '?' or '#'.
func urlSegmentAfter(ref, marker string) string {
	i := strings.Index(ref, marker)
	if i < 0 {
		return ""
	}
	seg := ref[i+len(marker):]
	if j := strings.IndexAny(seg, "/?#"); j >= 0 {
		seg = seg[:j]
	}
	return seg
}

// urlQueryValue returns key's value in ref's query string ("" when absent).
func urlQueryValue(ref, key string) string {
	if u, err := url.Parse(ref); err == nil {
		return u.Query().Get(key)
	}
	return ""
}

// slackChannelIDs resolves one slack_channel ref to namespaced channel ids.
func slackChannelIDs(ctx context.Context, d *db.DB, ref string) ([]string, error) {
	ref = strings.TrimSpace(ref)
	if seg := urlSegmentAfter(ref, "/archives/"); seg != "" {
		ref = seg
	} else if strings.HasPrefix(ref, "slack://") {
		ref = urlQueryValue(ref, "id")
	}
	ref = strings.TrimPrefix(ref, "#")
	if ref == "" {
		return nil, nil
	}
	rows, err := d.QueryContext(ctx, `SELECT id FROM channels
		WHERE id = ? OR substr(id, instr(id, ':') + 1) = ? OR lower(name) = lower(?)
		ORDER BY id`, ref, ref, ref)
	if err != nil {
		return nil, fmt.Errorf("resolving slack channel %q: %w", ref, err)
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("resolving slack channel %q: %w", ref, err)
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("resolving slack channel %q: %w", ref, err)
	}
	return ids, nil
}

// jiraProjectRef extracts the project key of a jira_project ref, "" when it
// has none.
func jiraProjectRef(ref string) string {
	ref = strings.TrimSpace(ref)
	for _, marker := range []string{"/browse/", "/projects/"} {
		if seg := urlSegmentAfter(ref, marker); seg != "" {
			ref = seg
			break
		}
	}
	key := strings.ToUpper(ref)
	if i := strings.LastIndex(key, "-"); i > 0 && isDigits(key[i+1:]) {
		key = key[:i] // an issue key names its project
	}
	if !jiraProjectKey.MatchString(key) {
		return ""
	}
	return key
}

func isDigits(s string) bool {
	return s != "" && strings.Trim(s, "0123456789") == ""
}

// confluenceSpaceRef extracts the space key of a confluence_space ref.
func confluenceSpaceRef(ref string) string {
	ref = strings.TrimSpace(ref)
	for _, marker := range []string{"/spaces/", "/display/"} {
		if seg := urlSegmentAfter(ref, marker); seg != "" {
			return seg
		}
	}
	if strings.ContainsAny(ref, "/ ") {
		return ""
	}
	return ref
}
