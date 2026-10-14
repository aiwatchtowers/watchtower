package automations

import (
	"fmt"
	"time"

	"github.com/dlclark/regexp2/v2"
	"github.com/dop251/goja"
)

// RegexpMatchTimeout bounds one backtracking regular-expression match (goja
// runs lookaround/backreference patterns on regexp2, which a pattern such as
// /(a+)+b(?=c)/ can keep busy for ever, out of the interrupt's reach). goja
// reports a timed-out match as "no match", so the RegExp methods are wrapped
// to throw a RangeError instead when a call takes this long.
const RegexpMatchTimeout = 2 * time.Second

// MaxBuiltinAlloc caps, in characters or elements, what one call of a known
// allocating builtin may produce: String.prototype.repeat/padStart/padEnd,
// String.raw, Array.prototype.join/fill, Array(n) and Array.from of an
// array-like. Beyond these the heap is not bounded: goja has no heap limit,
// and a script can still allocate a lot step by step (each step is
// interruptible, so the deadline bounds it in time, not in memory).
const MaxBuiltinAlloc = 16 * 1024 * 1024

// MaxJSONDepth caps the nesting JSON.stringify accepts: goja's native
// stringify is quadratic in depth (a 200k-deep object takes about a minute,
// out of the interrupt's reach). The depth is checked inside the replacer, on
// the values stringify actually serialises (after toJSON and getters).
const MaxJSONDepth = 1000

func init() {
	// regexp2/v2 is used by goja only (go mod why), so the default is ours to
	// set; every pattern goja compiles reads it.
	regexp2.DefaultMatchTimeout = RegexpMatchTimeout
}

// lockdownJS runs before the script. Every intrinsic the wrappers use is
// captured here, so a script that later replaces Set.prototype.has,
// Function.prototype.call, Math.floor or any other global changes nothing.
//   - Code from strings: eval, Function and Promise are deleted; every
//     function prototype's constructor throws EvalError.
//   - Allocation caps (MaxBuiltinAlloc) on the builtins listed there.
//   - JSON.stringify refuses nesting deeper than maxDepth.
//   - RegExp methods throw a RangeError when a call ran for timeoutMs (a
//     regexp2 match that timed out).
//
// It returns the function that neutralises one more function prototype.
const lockdownJS = `(function (g, maxAlloc, maxDepth, timeoutMs) {
	"use strict";
	var FunctionProto = Function.prototype;
	var uncurry = FunctionProto.bind.bind(FunctionProto.call);
	var apply = Reflect.apply, construct = Reflect.construct, defineProperty = Object.defineProperty;
	var getPrototypeOf = Object.getPrototypeOf, floor = Math.floor, now = Date.now;
	var NumberCtor = Number, StringCtor = String, isArray = Array.isArray;
	var RangeErrorCtor = RangeError, EvalErrorCtor = EvalError, WeakMapCtor = WeakMap;
	var wmGet = uncurry(WeakMap.prototype.get), wmSet = uncurry(WeakMap.prototype.set);
	var arrayIncludes = uncurry(Array.prototype.includes), arrayMap = uncurry(Array.prototype.map);
	var SymbolIterator = Symbol.iterator;

	function refuse() { throw new EvalErrorCtor("code generation from strings is not available to automation scripts"); }
	function neutralise(proto) {
		defineProperty(proto, "constructor", { value: refuse, writable: false, enumerable: false, configurable: false });
	}
	neutralise(FunctionProto);
	neutralise(getPrototypeOf(function* () {}));
	delete g.eval;
	delete g.Function;
	delete g.Promise;

	function toLen(v) {
		var n = NumberCtor(v);
		if (n !== n || n <= 0) { return 0; }
		return floor(n);
	}
	function relIndex(v, len, dflt) {
		var n = v === undefined ? dflt : NumberCtor(v);
		if (n !== n) { n = 0; }
		n = n < 0 ? floor(-n) * -1 : floor(n);
		if (n < 0) { return len + n < 0 ? 0 : len + n; }
		return n > len ? len : n;
	}
	function cap(what, n) {
		if (n > maxAlloc) { throw new RangeErrorCtor(what + ": the result would exceed " + maxAlloc + " characters or elements"); }
	}
	function guarded(obj, key, check) {
		var orig = obj[key];
		defineProperty(obj, key, { writable: true, configurable: true, enumerable: false,
			value: function () { check(this, arguments); return apply(orig, this, arguments); } });
	}

	var SP = String.prototype, AP = Array.prototype;
	guarded(SP, "repeat", function (s, a) { cap("repeat", StringCtor(s).length * toLen(a[0])); });
	guarded(SP, "padStart", function (s, a) { cap("padStart", toLen(a[0])); });
	guarded(SP, "padEnd", function (s, a) { cap("padEnd", toLen(a[0])); });
	guarded(String, "raw", function (s, a) {
		var cooked = a[0];
		if (cooked === null || cooked === undefined) { return; }
		var raw = cooked.raw;
		if (raw !== null && raw !== undefined) { cap("String.raw", toLen(raw.length)); }
	});
	guarded(AP, "join", function (arr, a) {
		var sep = a[0] === undefined ? 1 : StringCtor(a[0]).length;
		cap("join", toLen(arr.length) * (sep > 0 ? sep : 1));
	});
	guarded(AP, "fill", function (arr, a) {
		var len = toLen(arr.length);
		cap("fill", relIndex(a[2], len, len) - relIndex(a[1], len, 0));
	});
	guarded(Array, "from", function (s, a) {
		var src = a[0];
		if (src !== null && src !== undefined && typeof src[SymbolIterator] !== "function") { cap("Array.from", toLen(src.length)); }
	});
	function checkArrayArgs(args) {
		if (args.length === 1 && typeof args[0] === "number") { cap("Array", args[0]); }
	}
	// Array itself: a function (not a Proxy, which goja's instanceof refuses)
	// that checks Array(n) and constructs the real Array; it shares
	// Array.prototype and the statics, so instanceof, subclassing and species
	// keep working.
	var OrigArray = Array;
	function CappedArray() {
		checkArrayArgs(arguments);
		return construct(OrigArray, arguments, new.target === undefined ? OrigArray : new.target);
	}
	var ownKeys = Reflect.ownKeys(OrigArray), getOwn = Object.getOwnPropertyDescriptor;
	for (var i = 0; i < ownKeys.length; i++) {
		if (ownKeys[i] !== "length" && ownKeys[i] !== "name") { defineProperty(CappedArray, ownKeys[i], getOwn(OrigArray, ownKeys[i])); }
	}
	defineProperty(CappedArray, "name", { value: "Array", configurable: true });
	defineProperty(g, "Array", { value: CappedArray, writable: true, enumerable: false, configurable: true });
	defineProperty(AP, "constructor", { value: CappedArray, writable: true, enumerable: false, configurable: true });

	var stringify = JSON.stringify;
	defineProperty(JSON, "stringify", { writable: true, configurable: true, enumerable: false,
		value: function stringify_(value, replacer, space) {
			var depths = new WeakMapCtor();
			var userFn = typeof replacer === "function" ? replacer : null;
			var allow = null;
			if (userFn === null && isArray(replacer)) { allow = arrayMap(replacer, function (k) { return StringCtor(k); }); }
			function guard(key, val) {
				var d = wmGet(depths, this);
				if (d === undefined) { d = 0; }
				if (allow !== null && d > 0 && !isArray(this) && !arrayIncludes(allow, key)) { return undefined; }
				if (userFn !== null) { val = apply(userFn, this, [key, val]); }
				if (val !== null && typeof val === "object") {
					if (d + 1 > maxDepth) { throw new RangeErrorCtor("JSON.stringify: nesting deeper than " + maxDepth); }
					wmSet(depths, val, d + 1);
				}
				return val;
			}
			return stringify(value, guard, space);
		} });

	var RP = RegExp.prototype;
	function timed(key) {
		var orig = RP[key];
		// Fixed in place: a script can neither remove the timing nor reach
		// goja paths that misbehave without exec (a deleted exec panics).
		defineProperty(RP, key, { writable: false, configurable: false, enumerable: false,
			value: function () {
				var t0 = now();
				var out = apply(orig, this, arguments);
				if (now() - t0 >= timeoutMs) { throw new RangeErrorCtor("regular expression took too long (" + timeoutMs + " ms or more)"); }
				return out;
			} });
	}
	timed("exec");
	timed("test");
	timed(Symbol.match);
	timed(Symbol.matchAll);
	timed(Symbol.replace);
	timed(Symbol.search);
	timed(Symbol.split);
	return neutralise;
})`

// asyncProtoSources reach the async function prototype (scripts cannot
// write async, but its constructor compiles strings too). The pinned goja
// has no async generators (a syntax error), so there is no fourth one.
var asyncProtoSources = []string{
	`Object.getPrototypeOf(async function () {})`,
}

// returnJSONJS serialises the script's return value with the depth-checked
// JSON.stringify captured before the script ran; a function, symbol or
// BigInt anywhere is a ValidationError.
const returnJSONJS = `(function (stringify, ErrorCtor, StringCtor) {
	"use strict";
	function replacer(key, value) {
		var t = typeof value;
		if (t === "function" || t === "symbol" || t === "bigint") {
			var e = new ErrorCtor("the script returned a " + t + (key === "" ? "" : " under " + stringify(StringCtor(key))) + "; return JSON values only");
			e.name = "ValidationError";
			throw e;
		}
		return value;
	}
	return function (v) { return v === undefined ? undefined : stringify(v, replacer); };
})`

func (s *Sandbox) lockdown() error {
	lock, err := s.callable(lockdownJS)
	if err != nil {
		return err
	}
	nv, err := lock(goja.Undefined(), s.rt.GlobalObject(), s.rt.ToValue(MaxBuiltinAlloc), s.rt.ToValue(MaxJSONDepth),
		s.rt.ToValue(RegexpMatchTimeout.Milliseconds()))
	if err != nil {
		return fmt.Errorf("automation sandbox: locking down the runtime: %w", err)
	}
	neutralise, err := asCallable(nv, "neutralise")
	if err != nil {
		return err
	}
	for _, src := range asyncProtoSources {
		proto, err := s.rt.RunString(src)
		if err != nil {
			return fmt.Errorf("automation sandbox: reaching %s: %w", src, err)
		}
		if _, err := neutralise(goja.Undefined(), proto); err != nil {
			return fmt.Errorf("automation sandbox: neutralising %s: %w", src, err)
		}
	}
	return nil
}
