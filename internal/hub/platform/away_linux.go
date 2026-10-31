package platform

// NewAway on linux: no console to sit at, so the owner is always away.
func NewAway() Away { return alwaysAway{} }

type alwaysAway struct{}

func (alwaysAway) Away() (bool, error) { return true, nil }
