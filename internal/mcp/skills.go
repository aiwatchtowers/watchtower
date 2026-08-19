package mcp

import (
	"context"
	"errors"
	"strconv"
	"strings"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/skills"
)

// skillsNotConfiguredMsg is the graceful-degradation answer when the server
// was built without a skills directory (no workspace resolved).
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

// registerSkills exposes load_skill. It is a pure file read: no database, no
// writes. A disabled skill is deliberately still loadable — the enable toggle
// gates what the AVAILABLE SKILLS block lists, not what the read returns, so a
// model holding a stale list gets the instructions rather than a confusing
// error.
func registerSkills(s *mcpsdk.Server, skillsDir string) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "load_skill",
		Description: "Load one assistant skill by name — the full instructions for handling a class " +
			"of request. Call it when a skill listed in the AVAILABLE SKILLS block matches what the owner " +
			"is asking for, before doing the work, then follow what it says.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args loadSkillArgs) (*mcpsdk.CallToolResult, any, error) {
		name := strings.TrimSpace(args.Name)
		if name == "" {
			return errResult("name is required"), nil, nil
		}
		// Validate BEFORE any path is built: the name is the only caller-
		// supplied part of the path, so this is the traversal guard.
		if !skills.ValidName(name) {
			return errResult("invalid skill name " + strconv.Quote(name) +
				": must be lowercase letters, digits and dashes"), nil, nil
		}
		if skillsDir == "" {
			return errResult(skillsNotConfiguredMsg), nil, nil
		}
		skill, err := skills.Load(skillsDir, name)
		if errors.Is(err, skills.ErrNotFound) {
			return errResult("no skill named " + strconv.Quote(name)), nil, nil
		}
		if err != nil {
			return errResult("loading skill: " + err.Error()), nil, nil
		}
		return jsonResult(loadSkillResult{
			Name:        skill.Name,
			Description: skill.Description,
			Enabled:     skill.Enabled,
			Body:        skill.Body,
		})
	})
}
