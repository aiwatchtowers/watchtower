package prompts

import "fmt"

// Resolve is the one lookup every pipeline uses to load a registered prompt.
// It returns the prompt store's template for id and its version — the
// role-specific variant first when role is non-empty (Store.GetForRole) — or
// the built-in Defaults[id] at version 0 when store is nil, the read fails, or
// the stored template is empty (an empty template can never render: every
// caller formats it with arguments or appends to it).
//
// A non-nil err reports why a store was not used: a failed read, an empty
// stored row, or an id with neither a row nor a built-in default (then tmpl is
// empty too — every caller passes a registered id, so that is a programming
// error). The built-in default is still returned alongside it, so the caller
// keeps working and only has to log. A nil store or a missing row is not an
// error. GetForRole does not surface a failed role-variant read: it falls
// through to the base id's row.
func Resolve(store *Store, id, role string) (tmpl string, version int, err error) {
	if store != nil {
		tmpl, version, err = store.GetForRole(id, role)
		if err == nil && tmpl != "" {
			return tmpl, version, nil
		}
		if err == nil {
			err = fmt.Errorf("prompt %q: stored template is empty", id)
		}
	}
	return Defaults[id], 0, err
}

// WithRoleInstruction prepends the owner role's instruction block to a
// resolved template — the role-aware pipelines (digest, tracks, people,
// briefing) apply it to the stored and the built-in template alike. An
// unknown or empty role leaves the template unchanged.
func WithRoleInstruction(role, tmpl string) string {
	if instr := GetRoleInstruction(role); instr != "" {
		return instr + "\n\n" + tmpl
	}
	return tmpl
}
