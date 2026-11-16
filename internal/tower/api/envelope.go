// Package api holds the tower interface's wire types: the envelope every
// transport carries and each command's request and response. The Swift side
// is generated from these types, so a change here is a change to the
// interface.
package api

import "encoding/json"

// EnvelopeVersion is the version of the request envelope (Request.V).
const EnvelopeVersion = 1

// Request is one command call: {v, id, command, params}.
type Request struct {
	V       int             `json:"v"`
	ID      string          `json:"id"`
	Command string          `json:"command"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// Status is a response's outcome.
type Status string

const (
	// StatusOK: the command ran; Result holds its response.
	StatusOK Status = "ok"
	// StatusRefused: the command did not apply; Refusal says why.
	StatusRefused Status = "refused"
	// StatusUnknown: a non-idempotent command may or may not have acted
	// (it began and its outcome was not recorded). The client never resends.
	StatusUnknown Status = "unknown"
)

// Response answers a Request with the same ID.
type Response struct {
	ID      string          `json:"id"`
	Status  Status          `json:"status"`
	Result  json.RawMessage `json:"result,omitempty"`
	Refusal *Refusal        `json:"refusal,omitempty"`
}

// RefusalCode names why a command was refused.
type RefusalCode string

// The refusal codes; no other code exists.
const (
	CodeNotFound     RefusalCode = "not_found"
	CodeChanged      RefusalCode = "changed"
	CodeArgsChanged  RefusalCode = "args_changed"
	CodeReplyWaiting RefusalCode = "reply_waiting"
	CodeNotPermitted RefusalCode = "not_permitted"
	CodeUnsupported  RefusalCode = "unsupported"
)

// Refusal is a refused response's code and the sentence both clients show
// as is.
type Refusal struct {
	Code     RefusalCode `json:"code"`
	Sentence string      `json:"sentence"`
}

// WriteParams is embedded in every write command's request: the request_id
// the client makes once per press and keeps across its retries.
type WriteParams struct {
	RequestID string `json:"request_id"`
}
