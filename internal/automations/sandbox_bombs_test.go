package automations

import (
	"strings"
	"testing"
	"time"

	"github.com/dop251/goja"
)

// sandboxBombs are scripts that used to end the whole daemon: native
// recursion that overflows the Go stack (a fatal error no recover catches,
// so the run's abandon/auto-disable never ran and the daemon crash-looped on
// every tick) or one native call that allocates without bound (an OOM kill).
// Each must now throw a RangeError the script can catch, quickly — the test
// process surviving each one is the proof the daemon would.
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
	"JSON.stringify escapes":     `JSON.stringify("\x01".repeat(3e6))`,
	"JSON.stringify escaped key": `var o = {}; o["\x01".repeat(3e6)] = 1; JSON.stringify(o)`,
	"JSON.stringify indent":      `JSON.stringify(new Array(2e6).fill(1), null, 10)`,
	"toLocaleString":             `var s = "x".repeat(9 * 1024 * 1024); [s, s].toLocaleString()`,
	"typed toLocaleString":       `var s = "x".repeat(9 * 1024 * 1024); Number.prototype.toLocaleString = function () { return s }; new Uint8Array(2).toLocaleString()`,
	"bind chain":                 `var f = function () {}; for (var i = 0; i < 1e6; i++) { f = f.bind(null) }`,
	// Sparse (cheap to build): flat counts an array's length, holes included.
	"flat result size":    `var big = []; big.length = 9 * 1024 * 1024; [big, big].flat()`,
	"flatMap result size": `var big = []; big.length = 9 * 1024 * 1024; [1, 2].flatMap(function () { return big })`,
}

func TestSandbox_NativeBombsEndTheRunNotTheProcess(t *testing.T) {
	waitNoAbandonedRuns(t)
	for name, bomb := range sandboxBombs {
		t.Run(name, func(t *testing.T) {
			start := time.Now()
			got := mustRun(t, "try { "+bomb+"; return 'ran' } catch (e) { return e.name + ': ' + e.message }", sbOpts{})
			s, _ := got.(string)
			if !strings.HasPrefix(s, "RangeError: ") || time.Since(start) > 5*time.Second || AbandonedRuns() != 0 {
				t.Errorf("got %v after %v (abandoned %d); want a quick catchable RangeError", got, time.Since(start), AbandonedRuns())
			}
		})
	}
}

// Text that is not JSON from its start fails with goja's own SyntaxError,
// however many brackets follow; deep JSON gets the depth RangeError.
func TestSandbox_JSONParseNotJSONIsASyntaxError(t *testing.T) {
	got := mustRun(t, `var out = [];
		[ "note: " + "[".repeat(1001), "1 " + "[".repeat(1001), '{"a" ' + "[".repeat(1001), "[".repeat(1001) ].forEach(function (text) {
			try { JSON.parse(text); out.push("ran") } catch (e) { out.push(e.name) }
		});
		return out.join(",")`, sbOpts{})
	if got != "SyntaxError,SyntaxError,SyntaxError,RangeError" {
		t.Fatalf("got %v", got)
	}
}

func TestJSONNestsDeeper(t *testing.T) {
	cases := []struct {
		text string
		want bool
	}{
		{`[[1]]`, false},
		{strings.Repeat("[", 3), true},
		{" \n[ [\t[", true},
		{strings.Repeat("[", 2) + strings.Repeat("]", 2) + strings.Repeat("[", 3), false}, // trailing data after the value
		{`{"a":{"b":[1]}}`, true},
		{`{"a":1,"b":[[2]]}`, true},
		{`{"a":1,"b":[2,[3]]}`, true},
		{`{"a":1,"b":[2,3]}`, false},
		{`"[[[[[["`, false},
		{`["\"[[[[[", 1]`, false},
		{`["\\", [[[1]]]]`, true},
		{`[1, -2.5e+3, true, false, null, [[`, true},
		{`]]]][[[[`, false},            // goja fails at the first "]"
		{`note: [[[[`, false},          // not JSON from the start
		{`1 [[[`, false},               // a complete value, then trailing data
		{`[1 [[[`, false},              // a missing comma
		{`{[[[`, false},                // a key must be a string
		{`{"a" [[[`, false},            // a missing colon
		{`[tru [[[`, false},            // a broken literal
		{`["unterminated [[[[`, false}, // the string never closes
		{`[{"k":[{"k":[1]}]}]`, true},
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

// The wrapped replace, replaceAll, @@replace, flat, flatMap, toLocaleString,
// bind, JSON.stringify and JSON.parse return what goja's own builtins return,
// with the same side effects in the same order.
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
		`"aXbX".replaceAll(/X/g, "[$&]")`,
		`"abc".replace(/(?:)/g, "-")`,
		`"abc".replaceAll("", "$\x60.")`,
		`"abc".replace("zz", "q")`,
		`"abc".replace(/b/, undefined)`,
		`"abc".replace(/b/, 42)`,
		`"a1".replace(1, "$&$&")`,
		`/b/g[Symbol.replace]("abcb", "[$&$'$\x60]")`,
		`(function () { try { "a".replaceAll(/a/, "b") } catch (e) { return e.name } })()`,
		`(function () { try { String.prototype.replace.call(null, "a", "b") } catch (e) { return e.name } })()`,
		// A user @@replace gets the script's own value; conversions keep their order.
		`"abc".replace({ [Symbol.replace]: function (s, r) { return typeof r + ":" + r + ":" + s } }, "X$&")`,
		`"abc".replaceAll({ [Symbol.replace]: function (s, r) { return typeof r } }, function () {})`,
		`(function () { var log = [];
			var o = { toString: function () { log.push("o"); return "abc" } };
			var s = { get [Symbol.replace]() { log.push("get"); return undefined }, toString: function () { log.push("s"); return "b" } };
			var r = { toString: function () { log.push("r"); return "X" } };
			return String.prototype.replace.call(o, s, r) + " " + log.join(",") })()`,
		`(function () { var log = [];
			var re = /b/g; var r = { toString: function () { log.push("r"); return "X" } };
			var s = { toString: function () { log.push("s"); return "abcb" } };
			return re[Symbol.replace](s, r) + " " + log.join(",") })()`,
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
		// toLocaleString, arrays and typed arrays.
		`[1, "a", null, undefined, [2, 3], new Date(0).getTime()].toLocaleString()`,
		`(function () { var a = [1]; a.push(a); return a.toLocaleString() })()`,
		`Array.prototype.toLocaleString.call({ length: 2, 0: 1, 1: "b" })`,
		`(function () { try { [{ toLocaleString: 1 }].toLocaleString() } catch (e) { return e.name } })()`,
		`new Uint8Array([1, 2, 30]).toLocaleString()`,
		`new Float64Array([1.5, -2]).toLocaleString()`,
		`(function () { try { Uint8Array.prototype.toLocaleString.call([1]) } catch (e) { return e.name } })()`,
		// bind.
		`(function () { function f(a, b) { return this.k + a + b } var g = f.bind({ k: 1 }, 2); return [g.name, g.length, g(3), g.bind(null).name].join("|") })()`,
		`(function () { try { (function () {}).bind.call(1) } catch (e) { return e.name } })()`,
		`(function () { function F(a) { this.a = a } var B = F.bind(null, 7); return new B().a + "|" + (new B() instanceof F) })()`,
		// JSON.stringify with space and escapes.
		`JSON.stringify({ a: [1, { b: "x\ny\"z" }] }, null, {})`,
		`JSON.stringify({ a: [1] }, null, new Number(2))`,
		`JSON.stringify({ a: [1] }, null, new String("--"))`,
		`JSON.stringify({ "k\u0001": "\ud800é" })`,
		// JSON.parse with and without a reviver.
		`JSON.stringify(JSON.parse('{"a":[1,{"b":2}],"c":"[[[[","d":{}}'))`,
		`JSON.stringify(JSON.parse('{"a":[1,2,3],"b":{"c":1,"d":2}}', function (k, v) { return k === "d" || v === 2 ? undefined : v }))`,
		`JSON.stringify((function () { var seen = []; JSON.parse('{"x":[1,{"y":2}],"z":3}', function (k, v) { seen.push(k); return v }); return seen })())`,
		`JSON.parse('[1,2]', function (k, v) { return typeof v === "number" ? v * 10 : v }).join()`,
		`JSON.parse('"s"', "not a function")`,
		`(function () { try { JSON.parse("[1,") } catch (e) { return e.name } })()`,
		`(function () { try { JSON.parse("note: [[[[") } catch (e) { return e.name } })()`,
	}
	for _, expr := range exprs {
		want := plainGoja(t, "String("+expr+")")
		got := mustRun(t, "return String("+expr+")", sbOpts{})
		if got != want {
			t.Errorf("%s\n got  %q\n want %q", expr, got, want)
		}
	}
}

// ECMA-402: Array.prototype.toLocaleString passes its locales and options
// to each element's toLocaleString (goja's own passes nothing).
func TestSandbox_ToLocaleStringForwardsLocales(t *testing.T) {
	got := mustRun(t, `var e = { toLocaleString: function (l, o) { return l + "/" + o.k } };
		return [e, e].toLocaleString("de", { k: 1 })`, sbOpts{})
	if got != "de/1,de/1" {
		t.Fatalf("got %v", got)
	}
}
