package reviewmap

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// DBTitles is the TitleSource over the local database (tech spec §2.1
// "Lane titles"): board targets of workbench ProjectID by branch and by
// id, Jira summaries and the synced Jira projects. It never asks a
// service: a lane's ticket is only what the last sync stored.
type DBTitles struct {
	DB        *db.DB
	ProjectID int64
}

// Titles implements TitleSource.
func (s DBTitles) Titles(branches []string, jiraKeys []string, boardRefs []int64) (LaneTitles, error) {
	out := LaneTitles{
		BranchTargets: map[string]TargetTitle{},
		Jira:          map[string]string{},
		JiraProjects:  map[string]bool{},
		BoardRefs:     map[int64]TargetTitle{},
	}
	targets, err := s.DB.TargetsByBranches(s.ProjectID, branches)
	if err != nil {
		return LaneTitles{}, err
	}
	for _, b := range branches {
		if t, ok := targets[strings.TrimSpace(b)]; ok {
			out.BranchTargets[b] = TargetTitle{ID: int64(t.ID), Text: t.Text}
		}
	}
	if len(jiraKeys) > 0 {
		issues, err := s.DB.GetJiraIssuesByKeysMap(jiraKeys)
		if err != nil {
			return LaneTitles{}, fmt.Errorf("reading jira issues: %w", err)
		}
		for k, is := range issues {
			out.Jira[k] = is.Summary
		}
		projects, err := s.DB.ListSyncedJiraProjectKeys()
		if err != nil {
			return LaneTitles{}, err
		}
		for _, p := range projects {
			out.JiraProjects[p] = true
		}
	}
	for _, id := range boardRefs {
		t, err := s.DB.GetTargetByID(int(id))
		if errors.Is(err, sql.ErrNoRows) {
			continue // no such target: the ref is not a tag
		}
		if err != nil {
			return LaneTitles{}, err
		}
		if t.WorkbenchID.Valid && t.WorkbenchID.Int64 == s.ProjectID {
			out.BoardRefs[id] = TargetTitle{ID: id, Text: t.Text}
		}
	}
	return out, nil
}
