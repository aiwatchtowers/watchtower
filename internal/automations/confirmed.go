package automations

import "watchtower/internal/db"

// ScopeOf is the scope a's recipe parses in, rebuilt from its row: a
// built-in row's carries its built-in id (its sync trigger and builtin:
// capabilities parse only there).
func ScopeOf(a db.Automation) Scope {
	s := Scope{Kind: ScopeKind(a.Scope), WorkbenchID: a.ProjectID}
	if a.IsBuiltin() {
		s.BuiltinID = a.BuiltinID
	}
	return s
}

// ConfirmedRecipe is the recipe the owner last confirmed for a, parsed in a's
// scope; nil when a was never confirmed or its confirmed text is unknown.
// A confirmed a is its own text. Otherwise the candidates are, in order, the
// newest run snapshot at confirmed_hash and the recipe_text of the newest
// applied save_automation of a's file that pinned confirmed_hash (a save
// confirms its own text, spec §11 Execute); a candidate counts only if its
// approval hash computed now is confirmed_hash (a hash-format change such as
// D26's re-hash leaves none). Shared by `automations show` (the Changed
// block) and the authoring tools' widening.
func ConfirmedRecipe(d *db.DB, a *db.Automation) (*Recipe, error) {
	if a.ConfirmedHash == "" {
		return nil, nil
	}
	scope := ScopeOf(*a)
	candidates := []string{a.RecipeText}
	if a.ConfirmedHash != a.ApprovalHash || a.ParseError != "" {
		snapshot, err := d.AutomationRunSnapshotAt(a.ID, a.ConfirmedHash)
		if err != nil {
			return nil, err
		}
		candidates = []string{snapshot}
		// A save's scope is its folder's: "personal" for a built-in too.
		folder := Scope{Kind: scope.Kind, WorkbenchID: scope.WorkbenchID}
		save, err := d.LatestAppliedAutomationSave(a.Path, folder.String(), a.ConfirmedHash)
		if err != nil {
			return nil, err
		}
		if save != nil {
			candidates = append(candidates, save.RecipeText)
		}
	}
	for _, text := range candidates {
		r, err := ParseRecipe(a.Slug, []byte(text), scope)
		if err != nil || ApprovalHash(r) != a.ConfirmedHash {
			continue // not the confirmed text (or none): try the next candidate
		}
		return r, nil
	}
	return nil, nil
}
