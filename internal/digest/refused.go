package digest

import "context"

// RefusedGenerator fails every call with Err and starts nothing: the stand-in
// for a provider the organization's policy forbids (#608). There is no
// fallback to another provider.
type RefusedGenerator struct{ Err error }

// Generate implements Generator.
func (r RefusedGenerator) Generate(context.Context, string, string, string) (string, *Usage, string, error) {
	return "", nil, "", r.Err
}
