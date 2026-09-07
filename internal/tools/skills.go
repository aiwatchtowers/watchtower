package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"watchtower/internal/db"
	"watchtower/internal/skills"
)

// skillsNotConfiguredMsg is the graceful-degradation answer when the tool was
// built without a skills directory (no workspace resolved).
const skillsNotConfiguredMsg = "skills are not available: no skills directory is configured for this session"

type loadSkillArgs struct {
	Name string `json:"name" jsonschema:"skill name exactly as listed in the AVAILABLE SKILLS block (lowercase letters, digits and dashes)"`
}

// loadSkillResult is the tool payload: the instructions plus enough metadata
// for the model to know what it just loaded.
type loadSkillResult struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Enabled     bool   `json:"enabled"`
	Body        string `json:"body"`
}

// NewLoadSkill is the read tool loading one skill by name. It closes over the
// skills directory and is a pure file read: no database (the *db.DB is unused).
// A disabled skill is deliberately still loadable — the enable toggle gates
// what the AVAILABLE SKILLS block lists, not what the read returns, so a model
// holding a stale list gets the instructions rather than a confusing error.
func NewLoadSkill(skillsDir string) *Tool {
	return &Tool{
		Name: "load_skill",
		Description: "Load one assistant skill by name — the full instructions for handling a class " +
			"of request. Call it when a skill listed in the AVAILABLE SKILLS block matches what the owner " +
			"is asking for, before doing the work, then follow what it says.",
		InputSchema: mustSchema[loadSkillArgs]("load_skill"),
		Access:      AccessRead,
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			var a loadSkillArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			name := strings.TrimSpace(a.Name)
			if name == "" {
				return nil, &ValidationError{Msg: "name is required"}
			}
			// Validate BEFORE any path is built: the name is the only caller-
			// supplied part of the path, so this is the traversal guard.
			if !skills.ValidName(name) {
				return nil, &ValidationError{Msg: "invalid skill name " + strconv.Quote(name) +
					": must be lowercase letters, digits and dashes"}
			}
			if skillsDir == "" {
				return nil, errors.New(skillsNotConfiguredMsg)
			}
			skill, err := skills.Load(skillsDir, name)
			if errors.Is(err, skills.ErrNotFound) {
				return nil, fmt.Errorf("no skill named %s", strconv.Quote(name))
			}
			if err != nil {
				return nil, fmt.Errorf("loading skill: %w", err)
			}
			return loadSkillResult{
				Name:        skill.Name,
				Description: skill.Description,
				Enabled:     skill.Enabled,
				Body:        skill.Body,
			}, nil
		},
	}
}
