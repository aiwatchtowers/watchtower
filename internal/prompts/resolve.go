package prompts

// Resolve is the one lookup every pipeline uses to load a registered prompt.
// It returns the prompt store's template for id and its version — the
// role-specific variant first when role is non-empty (Store.GetForRole) — or
// the built-in Defaults[id] at version 0 when store is nil, the read fails, or
// the stored template is empty (an empty template can never render: every
// caller formats it with arguments or appends to it).
//
// err is non-nil only for a failed store read; the built-in default is still
// returned alongside it so the caller keeps working and only has to log. A nil
// store or a missing row is not an error.
func Resolve(store *Store, id, role string) (tmpl string, version int, err error) {
	if store != nil {
		tmpl, version, err = store.GetForRole(id, role)
		if err == nil && tmpl != "" {
			return tmpl, version, nil
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
