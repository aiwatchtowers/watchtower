# Feature: Jira Custom Fields Discovery & Mapping

## Problem
Jira boards use custom fields extensively — story points, T-shirt sizes, QA assignee, environments, severity, etc. Currently Watchtower ignores ALL custom fields during issue sync. The `story_points` column in `jira_issues` is always NULL. Board profile analysis reports "no estimation field" for every board.

## Goal
Automatically discover and map useful custom fields per board, so that:
1. Story points / estimation are synced into `jira_issues.story_points`
2. Board profile knows which custom fields matter for this board
3. Other useful custom fields (QA, severity, environment, etc.) are stored and available for analysis

## Design

### Phase 1: Field Discovery

**1.1 Fetch all custom fields from Jira API**
- Endpoint: `GET /rest/api/2/field` (already works with current scopes)
- Returns ~100+ custom fields with: `id`, `name`, `schema.type`, `schema.items`
- Store in new DB table `jira_custom_fields`:
  ```sql
  CREATE TABLE jira_custom_fields (
    id TEXT PRIMARY KEY,           -- "customfield_10016"
    name TEXT NOT NULL,            -- "Story point estimate"  
    field_type TEXT NOT NULL,      -- "number", "option", "user", "array", etc.
    items_type TEXT NOT NULL DEFAULT '',  -- for arrays: "option", "user", etc.
    is_useful INTEGER NOT NULL DEFAULT 0,
    usage_hint TEXT NOT NULL DEFAULT '',  -- LLM-generated: "estimation", "assignee_role", "categorization", etc.
    synced_at TEXT NOT NULL
  );
  ```
- Run during `jira sync` or `jira boards analyze` if table is empty or stale (>24h)

**1.2 LLM-based field classification**
- Send the list of custom fields (id, name, type) to LLM
- LLM classifies each as useful/not-useful and assigns a `usage_hint`:
  - `estimation` — story points, t-shirt size, effort
  - `assignee_role` — QA, developer, PM, delivery manager
  - `categorization` — area, environment, severity, discipline
  - `tracking` — branch, merge request, checklist progress
  - `planning` — planned start/end, kick-off, delivery commitment
  - `skip` — internal Jira fields, SLA, rank, color, form metadata
- Store `is_useful` and `usage_hint` in `jira_custom_fields`

### Phase 2: Board-Level Field Mapping

**2.1 Per-board field mapping table**
```sql
CREATE TABLE jira_board_field_map (
  board_id INTEGER NOT NULL,
  field_id TEXT NOT NULL,        -- "customfield_10016"
  role TEXT NOT NULL,            -- "story_points", "qa_assignee", "severity", etc.
  PRIMARY KEY (board_id, field_id)
);
```

**2.2 Auto-mapping during board analysis**
- During `AnalyzeBoard()`, after fetching raw data:
  - Sample 10-20 issues from the board with `fields=*all`
  - Check which `is_useful` custom fields have non-null values
  - LLM decides per-board mapping: which field_id maps to which role
  - Store in `jira_board_field_map`
- The estimation field mapping feeds into `BoardProfile.EstimationApproach`

### Phase 3: Sync Custom Field Values

**3.1 Extract values during issue sync**
- In `upsertIssue()`, after parsing standard fields:
  - Look up board's field map from `jira_board_field_map`
  - For `story_points` role: extract numeric value → `issue.StoryPoints`
  - For other roles: store in a new `custom_fields_json TEXT` column on `jira_issues`
    ```json
    {"qa": "John Doe", "severity": "Critical", "environment": "Production", "branch": "feature/xyz"}
    ```
  - A user-picker role (a user object, or an array of them, carrying `accountId`) also keeps its people under the reserved key `_people` (`db.CustomFieldPeopleKey`; a role mapped under that name is skipped): `{"qa": "John Doe", "_people": {"qa": [{"id": "<account id>", "name": "John Doe"}]}}`. The display value stays the names joined by ", " (picker fields sharing a role merge their people; a role that also holds a non-picker value keeps no `_people` entry, so its ids are not reported from that role). Atlassian Personal Data Reporting (`docs/features/company-setup.md`) reports these ids and, for a closed account, empties its `name` (the bare id stays) and rebuilds the role's display value from the names left. Rows synced before the key existed carry no ids until their next sync.

**3.2 Update board profile with estimation info**
- If a `story_points` mapping exists → `EstimationApproach.Type = "story_points"`, `Field = fieldID`
- Feed custom field summary into LLM prompt for richer board analysis

## API / CLI

```
watchtower jira fields                    # list discovered custom fields
watchtower jira fields discover           # force re-discover from API
watchtower jira fields map <board-id>     # show/edit field mapping for board
```

## Files to Modify

### New files:
- `internal/jira/fields.go` — field discovery, LLM classification, board mapping
- `cmd/jira_fields.go` — CLI commands

### Modified files:
- `internal/db/schema.sql` — new tables: `jira_custom_fields`, `jira_board_field_map`; new column `custom_fields_json` on `jira_issues`
- `internal/db/jira.go` — CRUD for new tables
- `internal/db/models.go` — new structs
- `internal/jira/sync.go` — extract custom field values during issue sync
- `internal/jira/board_analyzer.go` — integrate field mapping into board analysis
- `internal/jira/models.go` — raw issue fields parsing

## Implementation Order
1. DB schema (tables + migration)
2. Field discovery from API + LLM classification
3. Board-level auto-mapping during analyze
4. Custom field extraction during issue sync  
5. CLI commands
6. Desktop UI (future — show custom fields in board profile)
