package automations

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/dop251/goja"
)

// Living artifacts (Inbox builder A): a recipe with `artifacts: living`
// keeps one Inbox card per key. output.inbox({key}) writes the card of that
// key (the commit upserts it) and output.remove({key}) deletes it; both are
// buffered and committed only with a succeeded run (AUTO-04).

// outputRemove is output.remove, a verb on the output module, not an
// output kind (no outputs: [remove]).
const outputRemove = "remove"

// outputKey reads output.inbox's key: required in a living recipe, refused
// in a feed one.
func outputKey(env *Env, fn string, fields map[string]any) (string, error) {
	raw, has := fields["key"]
	switch living := keepsLivingArtifacts(env); {
	case !living && has:
		return "", validationf(`%s(): key is only for living artifacts; add "artifacts: living" to the recipe`, fn)
	case !living:
		return "", nil
	case !has:
		return "", validationf("%s(): key is required — this automation keeps living artifacts", fn)
	}
	return checkOutputKey(fn, raw)
}

// checkOutputKey is a living artifact's key: a string of 1 to
// MaxOutputKeyChars characters, not blank, without control characters. It
// is stored as given.
func checkOutputKey(fn string, raw any) (string, error) {
	k, ok := raw.(string)
	if !ok || strings.TrimSpace(k) == "" || utf8.RuneCountInString(k) > MaxOutputKeyChars ||
		!utf8.ValidString(k) || strings.ContainsFunc(k, unicode.IsControl) {
		return "", validationf("%s(): key must be a string of 1 to %d characters without control characters", fn, MaxOutputKeyChars)
	}
	return k, nil
}

// removeOutput is output.remove({key}): it buffers the deletion of the
// living card with that key (removing a key with no card is a no-op at the
// commit). outputs: [inbox] gates it and the recipe must say artifacts:
// living. A later output.inbox of the key in the same run re-creates the
// card; a later remove of a key written earlier in the run drops that
// write. In a dry run the step is dry_run and the call returns
// {status:"dry_run"}; a resumed run's replay runs it again.
func removeOutput(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
	const fn = "output." + outputRemove
	arg, _, argErr := argAt(env, rt, call, 0)
	return env.CallBuffered(StepKindOutput, outputRemove, arg, func(step *Step) (any, error) {
		m, err := manifestOf(env)
		if err != nil {
			return nil, err
		}
		entry, err := m.AllowOutput(outputKindInbox)
		if err != nil {
			return nil, err
		}
		step.SetPermission(entry)
		if argErr != nil {
			return nil, tooLargeAs(argErr, ErrNameResultTooLarge,
				fmt.Sprintf("%s(): the argument is larger than %d bytes", fn, maxSDKArgBytes))
		}
		if !keepsLivingArtifacts(env) {
			return nil, validationf(`%s(): only for living artifacts; add "artifacts: living" to the recipe`, fn)
		}
		fields, ok := arg.(map[string]any)
		if !ok {
			return nil, validationf("%s() takes an object {key}", fn)
		}
		for k := range fields {
			if k != "key" {
				return nil, validationf("%s(): unknown field %q", fn, k)
			}
		}
		key, err := checkOutputKey(fn, fields["key"])
		if err != nil {
			return nil, err
		}
		if err := env.Buffer.RemoveOutput(key); err != nil {
			return nil, err
		}
		if env.DryRun {
			return dryRunResult(step, arg), nil
		}
		return nil, nil
	})
}
