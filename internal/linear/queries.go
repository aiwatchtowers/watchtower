package linear

import "encoding/json"

// GraphQL operations against Linear's public schema. Every connection passes
// `first`; paginated ones page with pageInfo { hasNextPage endCursor } + after.

type pageInfo struct {
	HasNextPage bool   `json:"hasNextPage"`
	EndCursor   string `json:"endCursor"`
}

type idName struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type person struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
}

const queryViewer = `query { viewer { id name email organization { id name urlKey } teams(first: 100) { nodes { id } } } }`

type viewerData struct {
	Viewer struct {
		ID           string `json:"id"`
		Name         string `json:"name"`
		Email        string `json:"email"`
		Organization struct {
			ID     string `json:"id"`
			Name   string `json:"name"`
			URLKey string `json:"urlKey"`
		} `json:"organization"`
		Teams struct {
			Nodes []struct {
				ID string `json:"id"`
			} `json:"nodes"`
		} `json:"teams"`
	} `json:"viewer"`
}

const queryTeams = `query($after: String) { teams(first: 50, after: $after) { nodes { id key name } pageInfo { hasNextPage endCursor } } }`

type teamsData struct {
	Teams struct {
		Nodes []struct {
			ID   string `json:"id"`
			Key  string `json:"key"`
			Name string `json:"name"`
		} `json:"nodes"`
		PageInfo pageInfo `json:"pageInfo"`
	} `json:"teams"`
}

const queryUsers = `query($after: String) { users(first: 100, after: $after, includeDisabled: true) { nodes { id name displayName email } pageInfo { hasNextPage endCursor } } }`

type userNode struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	DisplayName string `json:"displayName"`
	Email       string `json:"email"`
}

type usersData struct {
	Users struct {
		Nodes    []userNode `json:"nodes"`
		PageInfo pageInfo   `json:"pageInfo"`
	} `json:"users"`
}

// Issues changed since $since in one team, archived ones included (they become
// is_deleted). On a first pass the filter also takes every open issue.
const queryIssues = `query($filter: IssueFilter!, $after: String) {
  issues(filter: $filter, first: 25, after: $after, includeArchived: true, orderBy: updatedAt) {
    nodes {
      id identifier previousIdentifiers title description url priority estimate dueDate
      createdAt updatedAt completedAt canceledAt archivedAt trashed startedAt
      team { id key } state { name type } assignee { id name email } creator { id name email }
      cycle { id } project { id } parent { id }
      labels(first: 20) { nodes { name } }
      relations(first: 20) { nodes { id type relatedIssue { id } } }
      history(first: 50) { nodes { id createdAt actor { id name }
        fromState { id name } toState { id name } fromAssignee { id name } toAssignee { id name } } }
    }
    pageInfo { hasNextPage endCursor }
  } }`

type historyNode struct {
	ID           string  `json:"id"`
	CreatedAt    string  `json:"createdAt"`
	Actor        *idName `json:"actor"`
	FromState    *idName `json:"fromState"`
	ToState      *idName `json:"toState"`
	FromAssignee *idName `json:"fromAssignee"`
	ToAssignee   *idName `json:"toAssignee"`
}

// issueNodeJSON is one issues node; raw keeps the node's JSON for raw_json.
type issueNodeJSON struct {
	ID                  string   `json:"id"`
	Identifier          string   `json:"identifier"`
	PreviousIdentifiers []string `json:"previousIdentifiers"`
	Title               string   `json:"title"`
	Description         *string  `json:"description"`
	URL                 string   `json:"url"`
	Priority            float64  `json:"priority"`
	Estimate            *float64 `json:"estimate"`
	DueDate             *string  `json:"dueDate"`
	CreatedAt           string   `json:"createdAt"`
	UpdatedAt           string   `json:"updatedAt"`
	CompletedAt         *string  `json:"completedAt"`
	CanceledAt          *string  `json:"canceledAt"`
	ArchivedAt          *string  `json:"archivedAt"`
	Trashed             *bool    `json:"trashed"`
	StartedAt           *string  `json:"startedAt"`
	Team                struct {
		ID  string `json:"id"`
		Key string `json:"key"`
	} `json:"team"`
	State struct {
		Name string `json:"name"`
		Type string `json:"type"`
	} `json:"state"`
	Assignee *person `json:"assignee"`
	Creator  *person `json:"creator"`
	Cycle    *idName `json:"cycle"`
	Project  *idName `json:"project"`
	Parent   *idName `json:"parent"`
	Labels   struct {
		Nodes []struct {
			Name string `json:"name"`
		} `json:"nodes"`
	} `json:"labels"`
	Relations struct {
		Nodes []struct {
			ID           string  `json:"id"`
			Type         string  `json:"type"`
			RelatedIssue *idName `json:"relatedIssue"`
		} `json:"nodes"`
	} `json:"relations"`
	History struct {
		Nodes []historyNode `json:"nodes"`
	} `json:"history"`

	raw json.RawMessage
}

type issuesData struct {
	Issues struct {
		Nodes    []json.RawMessage `json:"nodes"`
		PageInfo pageInfo          `json:"pageInfo"`
	} `json:"issues"`
}

const queryComments = `query($filter: CommentFilter!, $after: String) {
  comments(filter: $filter, first: 50, after: $after) {
    nodes { id body bodyData createdAt updatedAt user { id name } issue { id identifier } }
    pageInfo { hasNextPage endCursor } } }`

type commentNodeJSON struct {
	ID        string  `json:"id"`
	Body      string  `json:"body"`
	BodyData  *string `json:"bodyData"`
	CreatedAt string  `json:"createdAt"`
	UpdatedAt string  `json:"updatedAt"`
	User      *idName `json:"user"`
	Issue     *struct {
		ID         string `json:"id"`
		Identifier string `json:"identifier"`
	} `json:"issue"`
}

type commentsData struct {
	Comments struct {
		Nodes    []commentNodeJSON `json:"nodes"`
		PageInfo pageInfo          `json:"pageInfo"`
	} `json:"comments"`
}

const queryTeamPlanning = `query($team: String!) { team(id: $team) {
  cycles(first: 50, orderBy: updatedAt) { nodes { id number name startsAt endsAt completedAt progress } }
  projects(first: 50, orderBy: updatedAt) { nodes { id name state progress targetDate url lead { id } } } } }`

type cycleNode struct {
	ID          string  `json:"id"`
	Number      float64 `json:"number"`
	Name        *string `json:"name"`
	StartsAt    string  `json:"startsAt"`
	EndsAt      string  `json:"endsAt"`
	CompletedAt *string `json:"completedAt"`
	Progress    float64 `json:"progress"`
}

type projectNode struct {
	ID         string  `json:"id"`
	Name       string  `json:"name"`
	State      string  `json:"state"`
	Progress   float64 `json:"progress"`
	TargetDate *string `json:"targetDate"`
	URL        string  `json:"url"`
	Lead       *idName `json:"lead"`
}

type planningData struct {
	Team struct {
		Cycles struct {
			Nodes []cycleNode `json:"nodes"`
		} `json:"cycles"`
		Projects struct {
			Nodes []projectNode `json:"nodes"`
		} `json:"projects"`
	} `json:"team"`
}
