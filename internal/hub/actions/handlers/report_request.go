package handlers

import (
	"context"

	"watchtower/internal/hub/actions"
)

// SessionReportRequestHandler's messages, verbatim.
const (
	reportTimeoutMessage = "The Mac did not answer in time — check the session report on the Mac"
	reportNotFoundMsg    = "This session has no report on the Mac"
)

// ReportRequests takes the phone's session_report_request: a report run with
// the network (gh refreshes the PR states) at the runner's next pass, at most
// one per 60 s per session (SessionReportRunner.requestReport; false = within
// that spacing, nothing more run).
type ReportRequests interface {
	RequestReport(sessionID int64) bool
}

// sessionReportRequest is `session_report_request` (mobile POC spec §5.2,
// §4.8; entity the session id, params {}): asks the report runner for a run
// with the network at its next pass. A second request inside the runner's
// 60 s spacing is applied with nothing more run. Idempotent. A session
// outside the report window fails not_found: no report would ever reach the
// phone. The result is {}; the new report reaches the phone through the
// session_report slice.
func (h *Handlers) sessionReportRequest(ctx context.Context, r actions.Request) actions.Outcome {
	return h.withRequestTimeout(ctx, "session_report_request", reportTimeoutMessage, func(ctx context.Context) actions.Outcome {
		sessionID, ok := entityID(r)
		if !ok {
			return failed(reasonInvalidParams, "session_report_request needs a session id")
		}
		in := false
		if h.d.Windows != nil {
			var err error
			if in, err = h.d.Windows.InReportWindow(ctx, sessionID); err != nil {
				return failed(reasonWriteFailed, err.Error())
			}
		}
		if !in {
			return failed(reasonNotFound, reportNotFoundMsg)
		}
		if h.d.Reports != nil {
			h.d.Reports.RequestReport(sessionID)
		}
		return applied(nil)
	})
}
