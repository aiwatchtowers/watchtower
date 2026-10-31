package sources

import (
	"context"
	"database/sql"
	"time"
)

// ReportActiveWindow is how long after its last activity a session that is
// not live keeps its report (SessionReportSlice.activeWindow).
const ReportActiveWindow = 7 * 24 * time.Hour

// Published reports whether sessionID is one of the published sessions
// (TerminalSessionSlice.publishedSessions): the session_chat window, read by
// the session_chat_request handler (handlers.SessionWindows).
func (s *TerminalSessionSource) Published(ctx context.Context, sessionID int64) (bool, error) {
	_, ok, err := s.find(ctx, sessionID)
	return ok, err
}

// InReportWindow reports whether sessionID is in the session_report window
// (SessionReportSlice.window): a published session that is live or was
// active in the last ReportActiveWindow.
func (s *TerminalSessionSource) InReportWindow(ctx context.Context, sessionID int64) (bool, error) {
	p, ok, err := s.find(ctx, sessionID)
	if err != nil || !ok {
		return false, err
	}
	if p.state.live {
		return true, nil
	}
	last := parseDate(p.lastActiveAt)
	return last != nil && !last.Before(s.o.Now().Add(-ReportActiveWindow)), nil
}

// find is sessionID's published session.
func (s *TerminalSessionSource) find(ctx context.Context, sessionID int64) (publishedSession, bool, error) {
	var (
		out   publishedSession
		found bool
	)
	err := readTx(ctx, s.d, func(tx *sql.Tx) error {
		published, err := s.published(ctx, tx)
		for _, p := range published {
			if p.id == sessionID {
				out, found = p, true
				break
			}
		}
		return err
	})
	return out, found, err
}
