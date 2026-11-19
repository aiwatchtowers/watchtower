package tower

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// Spec describes how a command is called.
type Spec struct {
	// Read marks a command that only reads: no ledger and no request_id.
	Read bool
	// Idempotent marks a guarded write: re-running it is safe, so its done
	// ledger row commits with its write and a begun row is re-run. A write
	// that is not idempotent commits a begun row before it acts, and a
	// repeat of that begun row answers unknown.
	Idempotent bool
	// Grant is the hub grant the command needs.
	Grant string
	// ChangeTables are, for a read or a watch, the tables whose change
	// re-reads it; for a write, the tables it changes (Options.Changed).
	ChangeTables []string
	// Watch marks a command that streams changed events.
	Watch bool
	// IdempotentFor and GrantFor, when set, decide Idempotent and Grant from
	// the request's params (one command whose verbs differ).
	IdempotentFor func(params json.RawMessage) (bool, error)
	GrantFor      func(params json.RawMessage) (string, error)
}

// HandlerFunc runs one command.
type HandlerFunc[Req, Resp any] func(ctx context.Context, c *Ctx, req Req) (Resp, error)

// Command is one registered command, as the generator reads it.
type Command struct {
	Name      string
	Req, Resp reflect.Type
	Spec      Spec
}

// Registry is the table of commands. Its zero value is empty and ready.
type Registry struct {
	cmds map[string]registered
}

type registered struct {
	Command
	// decode reads the params into the command's request and returns the
	// call of its handler; a malformed request is refused before any work.
	decode func(params json.RawMessage) (func(ctx context.Context, c *Ctx) (any, error), error)
}

// Register adds the command name to r. It panics when name is taken.
func Register[Req, Resp any](r *Registry, name string, h HandlerFunc[Req, Resp], spec Spec) {
	if _, dup := r.cmds[name]; dup {
		panic(fmt.Sprintf("tower: command %q registered twice", name))
	}
	if r.cmds == nil {
		r.cmds = map[string]registered{}
	}
	r.cmds[name] = registered{
		Command: Command{Name: name, Req: reflect.TypeFor[Req](), Resp: reflect.TypeFor[Resp](), Spec: spec},
		decode: func(params json.RawMessage) (func(ctx context.Context, c *Ctx) (any, error), error) {
			var req Req
			if len(params) > 0 {
				if err := json.Unmarshal(params, &req); err != nil {
					return nil, Refuse(api.CodeUnsupported, "Watchtower couldn't read this request.")
				}
			}
			return func(ctx context.Context, c *Ctx) (any, error) { return h(ctx, c, req) }, nil
		},
	}
}

// Commands returns every registered command, sorted by name.
func (r *Registry) Commands() []Command {
	out := make([]Command, 0, len(r.cmds))
	for _, c := range r.cmds {
		out = append(out, c.Command)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// IsIdempotent reports whether a call of name with params is a guarded write.
func (r *Registry) IsIdempotent(name string, params json.RawMessage) (bool, error) {
	c, ok := r.cmds[name]
	if !ok {
		return false, fmt.Errorf("tower: unknown command %q", name)
	}
	if c.Spec.IdempotentFor != nil {
		return c.Spec.IdempotentFor(params)
	}
	return c.Spec.Idempotent, nil
}

// GrantFor returns the hub grant a call of name with params needs.
func (r *Registry) GrantFor(name string, params json.RawMessage) (string, error) {
	c, ok := r.cmds[name]
	if !ok {
		return "", fmt.Errorf("tower: unknown command %q", name)
	}
	if c.Spec.GrantFor != nil {
		return c.Spec.GrantFor(params)
	}
	return c.Spec.Grant, nil
}

// Ctx is what a handler gets besides its request.
type Ctx struct {
	DB     *db.DB
	Origin Origin
	Now    func() time.Time

	tower     *Tower
	command   string
	spec      Spec
	requestID string // "" for a read
	guarded   bool
	// stored is a guarded call's done result: the one its Write committed,
	// or the one a concurrent duplicate committed first.
	stored json.RawMessage
}
