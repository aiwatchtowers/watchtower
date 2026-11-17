package tower

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"watchtower/internal/tower/api"
)

// Call runs one request and answers it; it never fails, every error becomes
// a refused or unknown response. A read runs its handler, and so does a
// watch (the socket then streams its changed events). A write needs a
// request_id and goes through the request ledger (ledger.go).
func (t *Tower) Call(ctx context.Context, req api.Request, o Origin) api.Response {
	resp := api.Response{ID: req.ID}
	if req.V != api.EnvelopeVersion {
		return refused(resp, api.CodeUnsupported,
			fmt.Sprintf("This Watchtower doesn't speak request version %d. Update the app.", req.V))
	}
	cmd, ok := t.opts.Registry.cmds[req.Command]
	if !ok {
		return refused(resp, api.CodeUnsupported,
			fmt.Sprintf("This Watchtower doesn't know %q. Update the app.", req.Command))
	}
	run, err := cmd.decode(req.Params)
	if err != nil {
		return t.fail(resp, req.Command, err)
	}
	c := &Ctx{DB: t.db, Origin: o, Now: t.opts.Now, tower: t, command: req.Command, spec: cmd.Spec}
	if cmd.Spec.Read || cmd.Spec.Watch {
		out, err := run(ctx, c)
		if err != nil {
			return t.fail(resp, req.Command, err)
		}
		return t.answer(resp, req.Command, out)
	}
	return t.callWrite(ctx, resp, c, run, req.Params)
}

// answer marshals a handler's response into an ok response.
func (t *Tower) answer(resp api.Response, command string, out any) api.Response {
	b, err := json.Marshal(out)
	if err != nil {
		return t.fail(resp, command, fmt.Errorf("marshal the response: %w", err))
	}
	return ok(resp, b)
}

func ok(resp api.Response, result json.RawMessage) api.Response {
	resp.Status, resp.Result = api.StatusOK, result
	return resp
}

func refused(resp api.Response, code api.RefusalCode, sentence string) api.Response {
	resp.Status, resp.Refusal = api.StatusRefused, &api.Refusal{Code: code, Sentence: sentence}
	return resp
}

func unknown(resp api.Response) api.Response {
	resp.Status = api.StatusUnknown
	return resp
}

// FaultSentence is the refusal sentence of a fault when Options.Sentence is
// nil: a fixed sentence, so an error's own text (paths, SQL) never reaches a
// client.
const FaultSentence = "Watchtower couldn't do that. Try again."

// fail answers a refusal as is and any other error as unsupported, worded by
// Options.Sentence (default: FaultSentence).
func (t *Tower) fail(resp api.Response, command string, err error) api.Response {
	var r *RefusalError
	if errors.As(err, &r) {
		return refused(resp, r.Code, r.Sentence)
	}
	sentence := FaultSentence
	if t.opts.Sentence != nil {
		sentence = t.opts.Sentence(command, err)
	}
	return refused(resp, api.CodeUnsupported, sentence)
}
