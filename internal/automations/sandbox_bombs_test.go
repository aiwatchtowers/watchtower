package automations

import (
	"errors"
	"strings"
	"testing"

	"github.com/dop251/goja"
)

// sandboxBombs are scripts that used to end the whole daemon: native
// recursion that overflows the Go stack (a fatal error no recover catches,
// so the run's abandon/auto-disable never ran and the daemon crash-looped on
// every tick) or one native call that allocates without bound (an OOM kill).
// Each must now end its run quickly with an uncatchable limit RangeError —
// the test process surviving each one is the proof the daemon would.
var sandboxBombs = map[string]string{
	// Go-stack recursion (security review #5).
	"JSON.parse 16e6 deep":      `JSON.parse("[".repeat(16e6))`,
	"JSON.parse deep objects":   `JSON.parse('{"a":'.repeat(3e6) + "1" + "}".repeat(3e6))`,
	"JSON.parse reviver grafts": `var d = []; for (var i = 0; i < 5000; i++) { d = [d] } JSON.parse('{"a":1,"b":2}', function (k, v) { if (k === "a") { this.b = d } return v })`,
	"flat(Infinity) 3e6 deep":   `var a = []; for (var i = 0; i < 3e6; i++) { a = [a] } a.flat(Infinity)`,
	"flat(1e9) deep":            `var a = []; for (var i = 0; i < 5000; i++) { a = [a] } a.flat(1e9)`,
	"JSON.stringify 200k deep":  `var o = {}, c = o; for (var i = 0; i < 200000; i++) { c.a = {}; c = c.a } JSON.stringify(o)`,
	// One call, unbounded result. The $-backtick ones: 2e5 matches, about
	// 2e10 characters (goja collects every RegExp match before it
	// substitutes, so a bigger subject only takes longer to refuse).
	"replace $-backtick":         `"x".repeat(2e5).replace(/x/g, "$\x60")`,
	"replace $' with a string":   `"x".repeat(1e6).replace("x", "$'".repeat(1e6))`,
	"RegExp @@replace direct":    `/x/g[Symbol.replace]("x".repeat(2e5), "$\x60")`,
	"replaceAll 16 Mi insert":    `"x".repeat(1024).replaceAll("x", "y".repeat(16 * 1024 * 1024))`,
	"replaceAll function insert": `var big = "y".repeat(9 * 1024 * 1024); "xx".replaceAll("x", function () { return big })`,
	"replace $& amplifier":       `"x".repeat(4096).replace(/x+/, "$&".repeat(8 * 1024))`,
	"JSON.stringify huge array":  `var s = "x".repeat(16 * 1024 * 1024); JSON.stringify([s, s])`,
	"JSON.stringify String objs": `var s = new String("x".repeat(9 * 1024 * 1024)); JSON.stringify([s, s])`,
	"JSON.stringify indent":      `JSON.stringify(new Array(2e6).fill(1), null, 10)`,
	"toLocaleString":             `var s = "x".repeat(9 * 1024 * 1024); [s, s].toLocaleString()`,
	// Sparse (cheap to build): flat counts an array's length, holes included.
	"flat result size":    `var big = []; big.length = 9 * 1024 * 1024; [big, big].flat()`,
	"flatMap result size": `var big = []; big.length = 9 * 1024 * 1024; [1, 2].flatMap(function () { return big })`,
}

func TestSandbox_NativeBombsEndTheRunNotTheProcess(t *testing.T) {
	waitNoAbandonedRuns(t)
	for name, bomb := range sandboxBombs {
		t.Run(name, func(t *testing.T) {
			wantLimitHit(t, name, "try { "+bomb+"; return 'ran' } catch (e) { return 'caught ' + e.name }")
		})
	}
}

func TestSandbox_LimitHitNamesTheScriptLine(t *testing.T) {
	_, err := runScript(t, "var a = 1\nJSON.parse(\"[\".repeat(2000))", sbOpts{scriptLine: 10})
	var se *ScriptError
	if !errors.As(err, &se) || !se.Limit || se.Line != 11 || !strings.Contains(se.Error(), "line 11: RangeError: JSON.parse: the text is nested deeper than 1000 levels") {
		t.Fatalf("Run = %v; want a limit RangeError on line 11", err)
	}
}

func TestJSONNestsDeeper(t *testing.T) {
	cases := []struct {
		text string
		want bool
	}{
		{`[[1]]`, false},
		{strings.Repeat("[", 3), true},
		{strings.Repeat("[", 2) + strings.Repeat("]", 2) + strings.Repeat("[", 2), false},
		{`{"a":{"b":[1]}}`, true},
		{`"[[[[[["`, false},
		{`["\"[[[[[", 1]`, false},
		{`["\\", [[[1]]]]`, true},
		{`]]]][[[[`, false}, // goja fails at the first "]"
	}
	for _, c := range cases {
		if got := jsonNestsDeeper(c.text, 2); got != c.want {
			t.Errorf("jsonNestsDeeper(%q, 2) = %v; want %v", c.text, got, c.want)
		}
	}
}

// plainGoja runs script in a bare goja runtime (no lockdown), strict like a
// recipe script: the reference the wrapped builtins must agree with.
func plainGoja(t *testing.T, script string) string {
	t.Helper()
	v, err := goja.New().RunString(`"use strict"; ` + script)
	if err != nil {
		t.Fatalf("plain goja: %v", err)
	}
	return v.String()
}

// The wrapped replace, replaceAll, @@replace, flat, flatMap, toLocaleString
// and JSON.parse reviver return what goja's own builtins return.
func TestSandbox_WrappedBuiltinsMatchGoja(t *testing.T) {
	exprs := []string{
		// String templates: every $ pattern, string and RegExp searches.
		`"abcabc".replace("b", "[$$|$&|$\x60|$'|$0|$1|$<n>|$]")`,
		`"abcabc".replaceAll("b", "<$&$\x60$'>")`,
		`"a1b22c333".replace(/(\d)(\d)?/g, "[$1|$2|$3|$01|$02|$10|$00|$&]")`,
		`"a1b22c333".replace(/(?<d>\d)(?<e>\d)?/g, "[$<d>|$<e>|$<zz>|$<d|$1]")`,
		`"aaa".replace(/a/g, "$")`,
		`"aaa".replace(/a/g, "x$")`,
		`"aaa".replace(/(a)/g, "$11$9$1x")`,
		`"x".replace(/(((((((((((x)))))))))))/, "$11|$12|$111")`,
		`"aXbX".replaceAll("X", "-")`,
		`"abc".replace(/(?:)/g, "-")`,
		`"abc".replaceAll("", "$\x60.")`,
		`"abc".replace("zz", "q")`,
		`"abc".replace(/b/, undefined)`,
		`"abc".replace(/b/, 42)`,
		`/b/g[Symbol.replace]("abcb", "[$&$'$\x60]")`,
		// Function replacers keep their arguments and this.
		`"a1b2".replace(/(?<d>\d)/g, function () { return JSON.stringify([].slice.call(arguments)) + (this === undefined) })`,
		`"a1b2".replace("1", function (m, p, s) { return m + p + s })`,
		// flat / flatMap.
		`JSON.stringify([1, [2, [3, [4, [5]]]], , 6].flat())`,
		`JSON.stringify([1, [2, [3, [4, [5]]]]].flat(Infinity))`,
		`JSON.stringify([1, [2, [3]]].flat(0))`,
		`JSON.stringify([1, [2, [3]]].flat(-1))`,
		`JSON.stringify([1, [2, [3]]].flat("2"))`,
		`JSON.stringify([1, [2, [3]]].flat(NaN))`,
		`JSON.stringify([1, [2, , 3]].flat())`,
		`JSON.stringify(Array.prototype.flat.call({ length: 2, 0: [1, 2], 1: 3 }))`,
		`(function () { class L extends Array {} var r = L.from([1, [2]]).flat(); return (r instanceof L) + JSON.stringify(r) })()`,
		`JSON.stringify([1, 2].flatMap(function (x) { return [x, [x * 2]] }))`,
		`JSON.stringify([1, 2].flatMap(function (x) { return x + this.k }, { k: 1 }))`,
		`(function () { try { [1].flatMap(1) } catch (e) { return e.name } })()`,
		// toLocaleString.
		`[1, "a", null, undefined, [2, 3], new Date(0).getTime()].toLocaleString()`,
		`(function () { var a = [1]; a.push(a); return a.toLocaleString() })()`,
		`Array.prototype.toLocaleString.call({ length: 2, 0: 1, 1: "b" })`,
		`(function () { try { [{ toLocaleString: 1 }].toLocaleString() } catch (e) { return e.name } })()`,
		// JSON.parse with and without a reviver.
		`JSON.stringify(JSON.parse('{"a":[1,{"b":2}],"c":"[[[[","d":{}}'))`,
		`JSON.stringify(JSON.parse('{"a":[1,2,3],"b":{"c":1,"d":2}}', function (k, v) { return k === "d" || v === 2 ? undefined : v }))`,
		`JSON.stringify((function () { var seen = []; JSON.parse('{"x":[1,{"y":2}],"z":3}', function (k, v) { seen.push(k); return v }); return seen })())`,
		`JSON.parse('[1,2]', function (k, v) { return typeof v === "number" ? v * 10 : v }).join()`,
		`JSON.parse('"s"', "not a function")`,
		`(function () { try { JSON.parse("[1,") } catch (e) { return e.name } })()`,
	}
	for _, expr := range exprs {
		want := plainGoja(t, "String("+expr+")")
		got := mustRun(t, "return String("+expr+")", sbOpts{})
		if got != want {
			t.Errorf("%s\n got  %q\n want %q", expr, got, want)
		}
	}
}
