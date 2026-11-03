package digest

import "context"

// Preflight checks routing metadata without constructing a provider or claiming
// an attempt. The interface keeps the pipeline independent of its router.
func Preflight(ctx context.Context, gen Generator) error {
	if check, ok := gen.(interface{ RoutingPreflight(context.Context) error }); ok {
		return check.RoutingPreflight(ctx)
	}
	if wrapper, ok := gen.(generatorWrapper); ok {
		return Preflight(ctx, wrapper.wrappedGenerator())
	}
	return nil
}

// ProviderDeferred reports a pure provider wait. Multi-errors containing a real
// material/storage failure must retain the ordinary failure/poison policy.
func ProviderDeferred(err error) bool {
	if err == nil {
		return false
	}
	if wait, ok := err.(interface{ ProviderDeferred() bool }); ok {
		return wait.ProviderDeferred()
	}
	if many, ok := err.(interface{ Unwrap() []error }); ok {
		children := many.Unwrap()
		if len(children) == 0 {
			return false
		}
		for _, child := range children {
			if !ProviderDeferred(child) {
				return false
			}
		}
		return true
	}
	if one, ok := err.(interface{ Unwrap() error }); ok {
		return ProviderDeferred(one.Unwrap())
	}
	return false
}

// RoutingEnabled reports the metadata gate installed by the opt-in router.
func RoutingEnabled(gen Generator) bool {
	if _, ok := gen.(interface{ RoutingPreflight(context.Context) error }); ok {
		return true
	}
	if wrapper, ok := gen.(generatorWrapper); ok {
		return RoutingEnabled(wrapper.wrappedGenerator())
	}
	return false
}
