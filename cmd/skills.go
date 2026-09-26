package cmd

import (
	"log"

	"watchtower/internal/config"
	"watchtower/internal/skills"
)

// deployShippedSkills refreshes the shipped assistant skills in the workspace's
// skills directory. It is the single call site (daemon start, the
// ensureLegacy* precedent), so the Desktop app's managed daemon keeps shipped
// skills current without any user action.
//
// Everything here is log-only and non-fatal: an unwritable skills directory
// costs the owner three starter skills, never a daemon that refuses to start.
// The owner's own skills — and any shipped file they edited — are untouched by
// Deploy itself (see internal/skills/deploy.go).
func deployShippedSkills(cfg *config.Config, logger *log.Logger) {
	dir := skills.Dir(cfg.WorkspaceDir())
	statuses, err := skills.Deploy(dir)
	if err != nil {
		logger.Printf("skills: deploy failed: %v", err)
	}
	for _, s := range statuses {
		switch s.State {
		case skills.StateInstalled, skills.StateUpdated:
			logger.Printf("skills: %s %s", s.State, s.Path)
		case skills.StateForeign:
			logger.Printf("skills: %s not shipped over — a file we never wrote lives at %s", s.Name, s.Path)
		case skills.StateUnchanged, skills.StateDrifted:
			// Nothing happened (already current) or the file is the owner's
			// now — neither is worth a line on every daemon start.
		}
	}
	// Report files the catalog cannot list, so a broken skill (the owner's or
	// ours) is visible in the log instead of silently missing from chats.
	if _, skipped, err := skills.ListWithSkips(dir); err != nil {
		logger.Printf("skills: listing failed: %v", err)
	} else {
		for _, s := range skipped {
			logger.Printf("skills: skipping %s: %s", s.Path, s.Reason)
		}
	}
}
