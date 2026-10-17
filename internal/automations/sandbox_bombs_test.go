package automations

import (
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync"
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
	"flat(Infinity) 1e5 deep":   `var a = []; for (var i = 0; i < 1e5; i++) { a = [a] } a.flat(Infinity)`,
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
	"bind chain through Proxy":   `var f = function () {}; for (var i = 0; i < 1e6; i++) { f = new Proxy(f, {}).bind(null) }`,
	"Object.entries of a string": `Object.entries("x".repeat(16e6))`,
	"Object.keys of an array":    `var a = []; a.length = 1e6; Object.keys(new Array(5e5).fill(0))`,
	"JSON.parse many containers": `JSON.parse("[" + "[],".repeat(5e5) + "[]]")`,
	"JSON.parse many objects":    `JSON.parse("[" + "{},".repeat(5e5) + "{}]")`,
	"split per character":        `"x".repeat(16e6).split("")`,
	"split by a separator":       `"x,".repeat(4e5).split(",")`,
	"Array.from a string":        `Array.from("x".repeat(16e6))`,
	"Object.assign a string":     `Object.assign({}, "x".repeat(16e6))`,
	"global match count":         `"x".repeat(16e6).match(/x/g)`,
	"typed join separator":       `new Uint8Array(1e5).join("x".repeat(1e4))`,
	"typed join Float64":         `new Float64Array(16e6).fill(-1.2345678901234567e-300).join()`,
	"typed toString":             `String(new Float64Array(1e6).fill(-1.2345678901234567e-300))`,
	"normalize NFKD":             `"ﷺ".repeat(16e6).normalize("NFKD")`,
	"encodeURIComponent":         `encodeURIComponent("一".repeat(16e6))`,
	"escape":                     `escape("一".repeat(16e6))`,
	"apply array-like":           `Math.max.apply(null, { length: 4e9 })`,
	"Reflect.apply array-like":   `Reflect.apply(Math.max, null, { length: 4e9 })`,
	"Reflect.construct":          `Reflect.construct(Array, { length: 4e9 })`,
	"toSorted array-like":        `Array.prototype.toSorted.call({ length: 4e9 })`,
	"toReversed array-like":      `Array.prototype.toReversed.call({ length: 4e9 })`,
	"with array-like":            `Array.prototype.with.call({ length: 4e9 }, 0, 1)`,
	"toSpliced array-like":       `Array.prototype.toSpliced.call({ length: 4e9 }, 0, 0)`,
	"splice array-like":          `Array.prototype.splice.call({ length: 4e9 }, 0)`,
	"slice array-like":           `Array.prototype.slice.call({ length: 4e9 })`,
	"sort array-like":            `Array.prototype.sort.call({ length: 4e9 }, function (a, b) { return a - b })`,
	"typed from array-like":      `new Float64Array({ length: 4e9 })`,
	"TypedArray.from":            `Uint8Array.from({ length: 4e9 })`,
	"JSON.stringify toString":    `var big = "x".repeat(10 * 1024 * 1024), s = new String("a"); s.toString = function () { return big }; JSON.stringify([s, s, s])`,
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
		[ "note: " + "[".repeat(1001), "1 " + "[".repeat(1001), '{"a" ' + "[".repeat(1001), "[01" + "[".repeat(1001),
			'["\\x"' + "[".repeat(1001), '["a\x01b"' + "[".repeat(1001), "[".repeat(1001) ].forEach(function (text) {
			try { JSON.parse(text); out.push("ran") } catch (e) { out.push(e.name) }
		});
		return out.join(",")`, sbOpts{})
	if got != "SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,RangeError" {
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
		// goja stops at an invalid number, escape or raw control character.
		{`[[01, [[`, false},
		{`[1., [[[`, false},
		{`[-, [[[`, false},
		{`[1e, [[[`, false},
		{`["\x", [[[`, false},
		{`["\u12G4", [[[`, false},
		{"[\"a\x01b\", [[[", false},
		{`["é\n\/", [[1]]]`, true},
		{`[-0.5e-3, 10E+2, [[1]]]`, true},
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
		`(function () { var re = /\d/g; re.lastIndex = 5; var r = ("x".repeat(3e5) + "1a2").match(re); return r.join() + "|" + re.lastIndex })()`,
		`("y".repeat(3e5)).match(/x*/).length + "|" + "a,,b".split(",").length + "|" + "abc".split("").join("-") + "|" + "a-b-c".split("-", 2).join()`,
		`[Array.from("ab").join(), JSON.stringify(Object.assign({}, "ab")), "a1b2".match(/\d/g).join()].join("|")`,
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
		`new Float64Array([1.5, -2, NaN]).join() + "|" + new Int8Array([1, -2]).join(" - ") + "|" + String(new Uint8Array([1, 2]))`,
		`(function () { try { Uint8Array.prototype.join.call([1]) } catch (e) { return e.name } })()`,
		`["ẛ̣".normalize(), "ẛ̣".normalize("NFD"), "ẛ̣".normalize("NFKC"), "ﷺ".normalize("NFKD"), "abc".normalize()].join("|")`,
		`(function () { try { "a".normalize("NFX") } catch (e) { return e.name } })()`,
		`[encodeURI("a b/é?#"), encodeURIComponent("a b/é?#"), escape("a b/é一"), encodeURIComponent.name, encodeURI.length].join("|")`,
		`(function () { try { encodeURIComponent("\ud800") } catch (e) { return e.name } })()`,
		`[Math.max.apply(null, [1, 3, 2]), Reflect.apply(Math.min, null, [4, 2]), Reflect.construct(Array, [1, 2]).length, String.fromCharCode.apply(null, { length: 2, 0: 65, 1: 66 })].join("|")`,
		`[[3, 1, 2].toSorted().join(), [1, 2].toReversed().join(), [1, 2].with(0, 9).join(), [1, 2, 3].toSpliced(1, 1).join(), [1, 2, 3].slice(-2).join(), Array.prototype.slice.call({ length: 2, 0: "a" }).length].join("|")`,
		`(function () { var a = [1, 2, 3]; var r = a.splice(1, 1); return a.join() + "|" + r.join() })()`,
		`[new Uint8Array({ length: 2, 0: 7 }).join(), Uint8Array.from({ length: 2, 1: 3 }).join(), new Uint8Array([1, 2]).length].join("|")`,
		`(function () { try { Uint8Array.prototype.toLocaleString.call([1]) } catch (e) { return e.name } })()`,
		// bind.
		`(function () { function f(a, b) { return this.k + a + b } var g = f.bind({ k: 1 }, 2); return [g.name, g.length, g(3), g.bind(null).name].join("|") })()`,
		`(function () { try { (function () {}).bind.call(1) } catch (e) { return e.name } })()`,
		`(function () { function F(a) { this.a = a } var B = F.bind(null, 7); return new B().a + "|" + (new B() instanceof F) })()`,
		// JSON.stringify with space and escapes.
		`JSON.stringify({ a: [1, { b: "x\ny\"z" }] }, null, {})`,
		`JSON.stringify({ a: [1] }, null, new Number(2))`,
		`JSON.stringify([new Number(3), new String("s"), new Boolean(false), { b: new Boolean(true) }])`,
		`JSON.stringify({ a: new String("x"), b: new Number(1), c: 2 }, ["a", "b"])`,
		`(function () { var n = 0, s = new String("a"); s.toString = function () { n++; return "T" }; return JSON.stringify([s]) + n })()`,
		`(function () { var x = new Number(1); x.valueOf = function () { return 42 }; return JSON.stringify({ x: x }) })()`,
		`(function () { var B = function () {}; var P = new Proxy(B, {}).bind(null); return P.name })()`,
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

// BigInt is not available in automations (owner decision, ask #331): its
// ** and << operators build a result of any size in one native step. A
// BigInt literal is refused when the script compiles (the parsed program is
// walked, so a regex literal holding a quote cannot hide one), with a clear
// error, and nothing in the sandbox yields a BigInt.
func TestSandbox_BigIntNotAvailable(t *testing.T) {
	for _, script := range []string{
		`return 2n ** 4000000000n`,
		`return 1n << 40000000000n`,
		`var x = 0xffn`,
		`var x = 1_000n`,
		"var x = `${10n}`",
		`var r = /'/; return 2n ** 40n`,
		"var r = /`/; return 1n << 40n",
		`return (0n).constructor`,
		"var x = 1\nvar y = 5n",
	} {
		var pe *PreParseError
		_, err := NewSandbox(&Env{Ctx: t.Context(), Recipe: &Recipe{Script: script}, Journal: NewMemoryJournal(),
			Meter: NewMeter(Budget{Tokens: 1, Minutes: 1}, nil)}, nil)
		if !errors.As(err, &pe) || !pe.BigInt || !strings.Contains(err.Error(), "BigInt is not available in automations") {
			t.Errorf("NewSandbox(%q) = %v; want the BigInt refusal", script, err)
		}
		if _, err := ParseRecipe("x", []byte("---\nname: X\ntrigger:\n  manual: true\n---\n\n```js\n"+script+"\n```\n"), Scope{Kind: ScopePersonal}); err == nil ||
			!strings.Contains(err.Error(), "BigInt is not available in automations") {
			t.Errorf("ParseRecipe(%q) = %v; want the BigInt refusal", script, err)
		}
	}
	if _, err := ParseRecipe("x", []byte("---\nname: X\ntrigger:\n  manual: true\n---\n\n```js\nvar a = 1\nvar b = 5n\n```\n"), Scope{Kind: ScopePersonal}); err == nil ||
		!strings.Contains(err.Error(), "line 9") {
		t.Errorf("ParseRecipe of a BigInt on the script's second line = %v; want line 9", err)
	}
	got := mustRun(t, `var n1 = 2, a1n = 3; var s = "10n" + /5n/.source; // 7n
		return [a1n + n1, s, 1e5 + 0x1f + 0b1 + 0o7, typeof BigInt, typeof BigInt64Array, typeof BigUint64Array,
		typeof DataView.prototype.getBigInt64, typeof DataView.prototype.setBigInt64,
		typeof DataView.prototype.getBigUint64, typeof DataView.prototype.setBigUint64].join(",")`, sbOpts{})
	if want := "5,10n5n,100039," + strings.TrimSuffix(strings.Repeat("undefined,", 7), ","); got != want {
		t.Fatalf("got %v; want %s", got, want)
	}
}

// The heap watchdog stops a run whose heap grows past RunHeapBudget step by
// step, where no single call is over a cap (lowered here to keep the test
// light). The run fails with a RangeError; the process lives on.
func TestSandbox_HeapBudgetStopsTheRun(t *testing.T) {
	lowHeapBudget(t, 64<<20)
	for name, script := range map[string]string{
		"string doubling": `var s = "x"; try { for (;;) { s = s + s } } catch (e) { return "caught" }`,
		"many arrays":     `var keep = []; try { for (;;) { keep.push(new Array(1000).fill(1)) } } catch (e) { return "caught" }`,
		"string spread":   `var keep = []; try { for (;;) { keep.push([..."x".repeat(1e5)]) } } catch (e) { return "caught" }`,
	} {
		t.Run(name, func(t *testing.T) {
			_, err := runScript(t, script, sbOpts{})
			var se *ScriptError
			if !errors.As(err, &se) || se.Name != "RangeError" || !strings.Contains(se.Message, "too much memory") {
				t.Fatalf("Run = %v; want the memory RangeError", err)
			}
		})
	}
	// Under the budget nothing happens.
	if got := mustRun(t, `var a = []; for (var i = 0; i < 1e5; i++) { a.push(i) } return a.length`, sbOpts{}); got != float64(1e5) {
		t.Fatalf("got %v", got)
	}
}

// lowHeapBudget lowers RunHeapBudget for one test (the tests in this
// package do not run in parallel).
func lowHeapBudget(t *testing.T, budget uint64) {
	old := RunHeapBudget
	RunHeapBudget = budget
	t.Cleanup(func() { RunHeapBudget = old })
	runtime.GC() // a fresh live-heap reading for the run's baseline
}

// holdScript allocates mib MiB, keeps it and stays busy for ms.
func holdScript(mib, ms int) string {
	return fmt.Sprintf(`var keep = []; for (var i = 0; i < %d; i++) { keep.push("x".repeat(10 * 1024 * 1024) + i) }
		var end = Date.now() + %d; while (Date.now() < end) {} return keep.length`, mib/10, ms)
}

// Two runs under the budget each, together over it, do not stop each
// other: a run's baseline moves up when a sibling starts or ends.
func TestSandbox_HeapBudgetSparesSiblingRuns(t *testing.T) {
	lowHeapBudget(t, 96<<20)
	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i := range 2 {
		sb, _ := newTestSandbox(t, holdScript(60, 600), sbOpts{})
		wg.Add(1)
		go func() {
			defer wg.Done()
			time.Sleep(time.Duration(i) * 200 * time.Millisecond)
			_, errs[i] = sb.Run()
		}()
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("run %d: %v; want both to succeed", i, err)
		}
	}
}

// heldWhileWaiting keeps what the waiting module allocated alive.
var heldWhileWaiting []byte

// A waiting run is never stopped for memory: nothing is sampled while its
// meter is paused, and its baseline moves up when it resumes.
func TestSandbox_HeapBudgetSparesAWaitingRun(t *testing.T) {
	lowHeapBudget(t, 32<<20)
	t.Cleanup(func() { heldWhileWaiting = nil })
	wait := funcModule{name: "wait", fns: map[string]SDKFunc{
		"wait": func(env *Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
			env.Meter.PauseActive()
			defer env.Meter.ResumeActive()
			heldWhileWaiting = make([]byte, 128<<20) // someone else's memory, grown while this run waits
			for i := range heldWhileWaiting {
				heldWhileWaiting[i] = 1
			}
			runtime.GC()
			time.Sleep(100 * time.Millisecond)
			return nil, nil
		},
	}}
	_, err := runScript(t, `wait(); var end = Date.now() + 200; while (Date.now() < end) {} return 1`,
		sbOpts{modules: []Module{testModule(), wait}})
	if err != nil {
		t.Fatalf("Run = %v; want no memory stop for a waiting run", err)
	}
}

// Direct exec calls are timed too (the compiler rewrites them), so a
// catastrophic pattern in an exec loop throws instead of reading as "no
// match"; the prototype keeps goja's own exec.
func TestSandbox_ExecCallsAreTimed(t *testing.T) {
	for _, script := range []string{
		`var re = /(a+)+b(?=c)/g, s = "a".repeat(33), m, n = 0; while ((m = re.exec(s))) { n++ } return n`,
		`var re = /(a+)+b(?=c)/; return re["exec"]("a".repeat(33))`,
	} {
		start := time.Now()
		_, err := runScript(t, script, sbOpts{})
		var se *ScriptError
		if !errors.As(err, &se) || se.Name != "RangeError" || !strings.Contains(se.Message, "too long") {
			t.Errorf("%s → %v; want the regex timeout RangeError", script, err)
		}
		if took := time.Since(start); took > RegexpMatchTimeout+2*time.Second {
			t.Errorf("took %v", took)
		}
	}
	got := mustRun(t, `var re = /(\d)/g, out = [], m; while ((m = re.exec("a1b2"))) { out.push(m[1] + m.index) }
		var o = { exec: function (x) { return "own " + x } };
		return [out.join(), o.exec("y"), /b/["exec"]("abc")[0], RegExp.prototype.exec === /x/.exec,
			typeof $__automationExecProbe].join("|")`, sbOpts{})
	if got != "11,23|own y|b|true|undefined" {
		t.Fatalf("got %q", got)
	}
	if _, err := NewSandbox(&Env{Ctx: t.Context(), Recipe: &Recipe{Script: `var $__automationExec = 1`}, Journal: NewMemoryJournal(),
		Meter: NewMeter(Budget{Tokens: 1, Minutes: 1}, nil)}, nil); err == nil || !strings.Contains(err.Error(), "reserved") {
		t.Fatalf("a script naming the exec helper = %v; want a refusal", err)
	}
}

// Deleting RegExp.prototype.exec gives a catchable TypeError from the RegExp
// methods, as on main, never a Go panic.
func TestSandbox_DeletedExecIsATypeError(t *testing.T) {
	got := mustRun(t, `delete RegExp.prototype.exec; var out = [];
		[function () { return "a".replace(/a/, "b") }, function () { return /a/.test("a") },
			function () { return "a".match(/a/g) }, function () { return "a,b".split(/,/) },
			function () { return /a/.exec("a") }].forEach(function (f) {
			try { f(); out.push("ran") } catch (e) { out.push(e.name) }
		});
		return out.join(",")`, sbOpts{})
	if got != "TypeError,TypeError,TypeError,TypeError,TypeError" {
		t.Fatalf("got %v", got)
	}
}

// A run stopped for memory whose script then stays stuck in a native call
// is abandoned like any runaway: RunInterrupted{Abandoned: true}.
func TestSandbox_MemoryStopThenStuckIsAbandoned(t *testing.T) {
	waitNoAbandonedRuns(t)
	lowHeapBudget(t, 32<<20)
	var keep [][]byte
	stuck := funcModule{name: "stuck", fns: map[string]SDKFunc{
		"stuck": func(*Env, goja.FunctionCall, *goja.Runtime) (any, error) {
			keep = append(keep, make([]byte, 64<<20))
			for i := range keep[0] {
				keep[0][i] = 1
			}
			runtime.GC()
			time.Sleep(AbandonGrace + time.Second)
			return nil, nil
		},
	}}
	_, err := runScript(t, `stuck(); return 1`, sbOpts{modules: []Module{testModule(), stuck}})
	var ri *RunInterrupted
	if !errors.As(err, &ri) || !ri.Abandoned || ri.Reason != InterruptMemory {
		t.Fatalf("Run = %v; want an abandoned memory interrupt", err)
	}
	waitNoAbandonedRuns(t)
}
