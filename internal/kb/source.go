package kb

import (
	"context"
	"time"
)

// Source renders one kind of document. Implementations read only through the
// Queryer they are given (the single SQLite connection may be inside a tx).
type Source interface {
	Name() string
	// Changed returns the document keys touched since cursor, the next cursor,
	// and whether the source is caught up (false = call again with next).
	Changed(ctx context.Context, q Queryer, cursor string, now time.Time) (keys []string, next string, done bool, err error)
	// Keys lists every document key that currently exists (daily reconcile).
	Keys(ctx context.Context, q Queryer) ([]string, error)
	// Build renders one document; nil means it no longer exists.
	Build(ctx context.Context, q Queryer, key string) (*Doc, error)
}

// progressReporter is implemented by sources whose backfill can be partial
// (Slack): Progress is the share of the source already indexed, 0..1 (the
// exact figure `kb status` shows); Backfilling reports whether the index is
// far enough behind for search results to say so.
type progressReporter interface {
	Progress(ctx context.Context, q Queryer, cursor string) (float64, error)
	Backfilling(ctx context.Context, q Queryer, cursor string) (bool, error)
}

// allSources is the indexing order: small sources first so everything but
// Slack is searchable after the first budgeted cycle, Slack (the backfill
// giant) last.
func allSources() []Source {
	return []Source{
		calendarSource{},
		ideaSource{},
		digestSource{},
		streamDigestSource{},
		recapSource{},
		transcriptSource{},
		jiraSource{},
		imapSource{},
		gmailSource{},
		newSlackSource(),
	}
}

func sourceNames() []string {
	var out []string
	for _, s := range allSources() {
		out = append(out, s.Name())
	}
	return out
}

func sourceByName(name string) Source {
	for _, s := range allSources() {
		if s.Name() == name {
			return s
		}
	}
	return nil
}

// splitRef splits "<prefix><rest>" and reports whether prefix matched.
func splitRef(ref, prefix string) (string, bool) {
	if len(ref) <= len(prefix) || ref[:len(prefix)] != prefix {
		return "", false
	}
	return ref[len(prefix):], true
}

// maxString returns the larger of two ISO/number-as-text cursors compared as strings.
func maxString(a, b string) string {
	if b > a {
		return b
	}
	return a
}
