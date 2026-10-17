package automations

import (
	"fmt"
	"strings"
	"time"
	"unicode/utf16"

	"github.com/dlclark/regexp2/v2"
	"github.com/dop251/goja"
)

// RegexpMatchTimeout bounds one backtracking regular-expression match (goja
// runs lookaround/backreference patterns on regexp2, which a pattern such as
// /(a+)+b(?=c)/ can keep busy for ever, out of the interrupt's reach). goja
// reports a timed-out match as "no match", so the RegExp methods are wrapped
// to throw a RangeError instead when a call takes this long.
const RegexpMatchTimeout = 2 * time.Second

// MaxBuiltinAlloc caps the cheap amplifiers, in characters, elements or
// bytes per call: String.prototype.repeat/padStart/padEnd/concat, the text
// replace/replaceAll/RegExp@@replace insert, String.raw,
// Array.prototype.join/toLocaleString/fill/concat/flat/flatMap, Array(n),
// Array.from of an array-like, ArrayBuffer and typed-array lengths, and the
// JSON.stringify result. The heap is not bounded (v1 limit): goja has no
// heap limit, and a script can still allocate a lot step by step (each step
// is interruptible, so the deadline bounds it in time, not in memory).
const MaxBuiltinAlloc = 16 * 1024 * 1024

// MaxDefaultSortLength is the longest array Array.prototype.sort (and the
// typed-array sort) sorts without a comparator: that sort runs natively, out
// of the interrupt's reach; with a comparator every comparison is
// interruptible JS.
const MaxDefaultSortLength = 1000000

// MaxJSONDepth caps the nesting JSON.stringify, JSON.parse (and its reviver
// walk) and Array.prototype.flat accept. goja's native stringify is quadratic
// in depth (a 200k-deep object takes about a minute, out of the interrupt's
// reach); its JSON.parse and flat recurse on the Go stack, and a deep enough
// input ("[".repeat(16e6)) overflows it — a fatal error no recover catches,
// which would end the whole daemon. The stringify depth is checked inside
// the replacer, on the values stringify actually serialises (after toJSON
// and getters); the parse depth by scanning the text (jsonNestsDeeper)
// before goja parses it; the reviver walk runs as JS, and flat as one
// native flatMap pass per level. Function.prototype.bind chains are capped
// at the same depth (each bind prefixes "bound " to the name, so a long
// chain grows quadratically).
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
//   - Size and depth limits: the allocation caps (MaxBuiltinAlloc) on the
//     builtins listed there, nesting deeper than maxDepth in
//     JSON.stringify, JSON.parse and flat, and bind chains deeper than
//     maxDepth, all checked before (or while counting) what goja builds, so
//     the native work stays bounded. Each throws a catchable RangeError.
//   - No default sort of more than MaxDefaultSortLength elements.
//   - RegExp methods throw a RangeError when a call ran for timeoutMs (a
//     regexp2 match that timed out).
//
// It returns the function that neutralises one more function prototype.
const lockdownJS = `(function (g, maxAlloc, maxDepth, timeoutMs, maxSort, jsonNestsDeeper, quotedLength, classOf) {
	"use strict";
	var FunctionProto = Function.prototype;
	var uncurry = FunctionProto.bind.bind(FunctionProto.call);
	var apply = Reflect.apply, construct = Reflect.construct, defineProperty = Object.defineProperty;
	var reflectDefine = Reflect.defineProperty, reflectDelete = Reflect.deleteProperty, objectKeys = Object.keys;
	var getPrototypeOf = Object.getPrototypeOf, floor = Math.floor, min = Math.min, now = Date.now;
	var NumberCtor = Number, StringCtor = String, ObjectCtor = Object, isArray = Array.isArray;
	var RangeErrorCtor = RangeError, EvalErrorCtor = EvalError, WeakMapCtor = WeakMap;
	var wmGet = uncurry(WeakMap.prototype.get), wmSet = uncurry(WeakMap.prototype.set);
	var arrayIncludes = uncurry(Array.prototype.includes), arrayPush = uncurry(Array.prototype.push);
	var arrayPop = uncurry(Array.prototype.pop);
	var objectToString = uncurry(Object.prototype.toString);
	var strIndexOf = uncurry(String.prototype.indexOf), strSlice = uncurry(String.prototype.slice);
	var strCharAt = uncurry(String.prototype.charAt), strCharCodeAt = uncurry(String.prototype.charCodeAt);
	var SymbolIterator = Symbol.iterator, SymbolSpreadable = Symbol.isConcatSpreadable, TypeErrorCtor = TypeError;
	var SymbolMatch = Symbol.match, SymbolReplace = Symbol.replace;
	var origJoin = Array.prototype.join;

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
	function limit(msg) { throw new RangeErrorCtor(msg); }
	function cap(what, n) {
		if (n > maxAlloc) { limit(what + ": the result would exceed " + maxAlloc + " characters or elements"); }
	}
	function toIntegerOrInfinity(v) {
		var n = NumberCtor(v);
		if (n !== n) { return 0; }
		if (n === Infinity || n === -Infinity) { return n; }
		return n < 0 ? -floor(-n) : floor(n);
	}
	function dataProperty(v) { return { value: v, writable: true, enumerable: true, configurable: true }; }
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
	guarded(AP, "fill", function (arr, a) {
		var len = toLen(arr.length);
		cap("fill", relIndex(a[2], len, len) - relIndex(a[1], len, 0));
	});
	guarded(Array, "from", function (s, a) {
		var src = a[0];
		if (src !== null && src !== undefined && typeof src[SymbolIterator] !== "function") { cap("Array.from", toLen(src.length)); }
	});
	guarded(AP, "concat", function (arr, a) {
		var total = spreadLength(arr);
		for (var i = 0; i < a.length; i++) { total += spreadLength(a[i]); cap("concat", total); }
		cap("concat", total);
	});
	function spreadLength(v) {
		if (v === null || typeof v !== "object") { return 1; }
		var spread = v[SymbolSpreadable];
		return (spread === undefined ? isArray(v) : !!spread) ? toLen(v.length) : 1;
	}
	guarded(AP, "sort", function (arr, a) {
		if (a[0] === undefined && toLen(arr.length) > maxSort) {
			throw new RangeErrorCtor("sort: arrays longer than " + maxSort + " need a comparator function");
		}
	});

	// join converts each element once, checking the running result length.
	defineProperty(AP, "join", { writable: true, configurable: true, enumerable: false,
		value: function join(separator) {
			var len = toLen(this.length);
			cap("join", len);
			var sep = separator === undefined ? "," : StringCtor(separator);
			var parts = [], total = 0;
			for (var i = 0; i < len; i++) {
				var e = this[i];
				var str = e === undefined || e === null ? "" : StringCtor(e);
				total += str.length + (i > 0 ? sep.length : 0);
				cap("join", total);
				arrayPush(parts, str);
			}
			return apply(origJoin, parts, [sep]);
		} });

	// toLocaleString as goja runs it (an array already being converted reads
	// as ""), checking the running result length; locales and options reach
	// each element's toLocaleString. Typed arrays share it (their elements'
	// toLocaleString can be replaced too), after their own receiver check.
	var localeStack = [];
	function localeJoin(o, len, args) {
		if (arrayIncludes(localeStack, o)) { return ""; }
		arrayPush(localeStack, o);
		try {
			var parts = [], total = 0;
			for (var i = 0; i < len; i++) {
				var e = o[i], str = "";
				if (e !== undefined && e !== null) {
					var f = e.toLocaleString;
					if (typeof f !== "function") { throw new TypeErrorCtor("Property 'toLocaleString' of object " + StringCtor(e) + " is not a function"); }
					str = StringCtor(apply(f, e, args));
				}
				total += str.length + (i > 0 ? 1 : 0);
				cap("toLocaleString", total);
				arrayPush(parts, str);
			}
			return apply(origJoin, parts, [","]);
		} finally {
			arrayPop(localeStack);
		}
	}
	defineProperty(AP, "toLocaleString", { writable: true, configurable: true, enumerable: false,
		value: function toLocaleString() {
			if (this === null || this === undefined) { throw new TypeErrorCtor("Array.prototype.toLocaleString called on null or undefined"); }
			var o = ObjectCtor(this);
			return localeJoin(o, toLen(o.length), arguments);
		} });

	// bind chains: each bound name is "bound " + the target's name.
	var bindDepth = new WeakMapCtor(), origBind = FunctionProto.bind;
	defineProperty(FunctionProto, "bind", { writable: true, configurable: true, enumerable: false,
		value: function bind(thisArg) {
			var d = (typeof this === "function" ? wmGet(bindDepth, this) : undefined) || 0;
			if (d >= maxDepth) { limit("bind: a chain of more than " + maxDepth + " bound functions"); }
			var f = apply(origBind, this, arguments);
			wmSet(bindDepth, f, d + 1);
			return f;
		} });

	// flat flattens one level per native flatMap pass (goja's own flat
	// recurses on the Go stack): a pass counts the result's elements, and
	// arrays still nested after maxDepth passes end the run. flat(0) and
	// below flatten nothing, so goja's flat runs them.
	var origFlat = AP.flat, origFlatMap = AP.flatMap;
	defineProperty(AP, "flat", { writable: true, configurable: true, enumerable: false,
		value: function flat() {
			var depth = arguments.length > 0 && arguments[0] !== undefined ? toIntegerOrInfinity(arguments[0]) : 1;
			if (depth < 1) { return apply(origFlat, this, [0]); }
			var total = 0, nested = false;
			function pass(el) {
				if (isArray(el)) { nested = true; total += toLen(el.length); } else { total += 1; }
				cap("flat", total);
				return el;
			}
			var out = this;
			for (var level = 0; ; level++) {
				if (level === maxDepth) { limit("flat: arrays nested deeper than " + maxDepth + " levels"); }
				total = 0;
				nested = false;
				out = apply(origFlatMap, out, [pass]);
				depth--;
				if (!nested || depth < 1) { return out; }
			}
		} });
	// flatMap flattens one level natively; the callback's results are counted.
	defineProperty(AP, "flatMap", { writable: true, configurable: true, enumerable: false,
		value: function flatMap(callback) {
			if (typeof callback !== "function") { return apply(origFlatMap, this, arguments); }
			var total = 0;
			var counted = function () {
				var r = apply(callback, this, arguments);
				total += isArray(r) ? toLen(r.length) : 1;
				cap("flatMap", total);
				return r;
			};
			return apply(origFlatMap, this, [counted, arguments[1]]);
		} });

	// replaceArg is the replace value handed to goja's built-in string or
	// RegExp replace (a user @@replace gets the script's own value). A
	// replacement with no $ pattern goes as it is when the matches are
	// bounded (a string search: at most length + 1) and the result cannot
	// pass maxAlloc; anything else becomes a function that returns the same
	// text goja would insert for each match (substitute mirrors goja's
	// writeSubstitution: $$, $&, the $-backtick prefix, $', $n/$nn,
	// $<name>) and throws once the inserted text passes maxAlloc (the prefix
	// pattern for every match, or a 16 Mi replacement for every match, is
	// quadratic).
	function replaceArg(what, subject, replaceValue, boundedMatches) {
		var total = 0;
		function add(n) {
			total += n;
			if (total > maxAlloc) { limit(what + ": the result would exceed " + maxAlloc + " characters"); }
		}
		if (typeof replaceValue === "function") {
			return function () {
				var r = StringCtor(apply(replaceValue, this, arguments));
				add(r.length);
				return r;
			};
		}
		var template = StringCtor(replaceValue), tl = template.length;
		if (strIndexOf(template, "$") < 0) {
			if (boundedMatches && subject.length + (subject.length + 1) * tl <= maxAlloc) { return template; }
			return function () { add(tl); return template; };
		}
		return function () {
			// (match, captures…, position, subject[, groups]): position is a
			// number, captures are strings or undefined.
			var n = arguments.length, groups, str, position;
			if (typeof arguments[n - 2] === "string") {
				groups = arguments[n - 1]; str = arguments[n - 2]; position = arguments[n - 3]; n -= 3;
			} else {
				str = arguments[n - 1]; position = arguments[n - 2]; n -= 2;
			}
			return substitute(template, str, position, arguments, n, groups, add);
		};
	}
	// stringReplace is String.prototype.replace/replaceAll in goja's order:
	// an object search with an @@replace method gets the call with the
	// script's own replace value (RegExp's built-in @@replace counts for
	// itself); otherwise the subject, the search and then the replace value
	// are converted, and goja's string path runs with the counted value.
	function stringReplace(what, orig, all, o, searchValue, replaceValue) {
		if (o === null || o === undefined) { throw new TypeErrorCtor("String.prototype." + what + " called on null or undefined"); }
		if (searchValue !== null && (typeof searchValue === "object" || typeof searchValue === "function")) {
			if (all) {
				var m = searchValue[SymbolMatch];
				if (m !== undefined ? !!m : classOf(searchValue) === "RegExp") {
					var flags = searchValue.flags;
					if (flags === null || flags === undefined) { throw new TypeErrorCtor("String.prototype.replaceAll called with a RegExp without flags"); }
					if (strIndexOf(StringCtor(flags), "g") < 0) { throw new TypeErrorCtor("String.prototype.replaceAll called with a non-global RegExp argument"); }
				}
			}
			var replacer = searchValue[SymbolReplace];
			if (replacer !== undefined && replacer !== null) {
				if (typeof replacer !== "function") { throw new TypeErrorCtor("Symbol.replace is not a function"); }
				return apply(replacer, searchValue, [o, replaceValue]);
			}
		}
		var str = StringCtor(o), search = StringCtor(searchValue);
		return apply(orig, str, [search, replaceArg(what, str, replaceValue, true)]);
	}
	function substitute(template, subject, position, caps, numCaps, groups, add) {
		var out = [], tl = template.length, i = 0, matched = caps[0];
		var tail = position + matched.length, sl = subject.length, piece;
		while (i < tl) {
			var d = strIndexOf(template, "$", i);
			if (d < 0 || d === tl - 1) {
				piece = strSlice(template, i);
				add(piece.length);
				arrayPush(out, piece);
				break;
			}
			if (d > i) {
				piece = strSlice(template, i, d);
				add(piece.length);
				arrayPush(out, piece);
			}
			var ch = strCharAt(template, d + 1);
			i = d + 2;
			if (ch === "$") { piece = "$"; }
			else if (ch === "&") { piece = matched; }
			else if (ch === "\x60") { piece = strSlice(subject, 0, position); }
			else if (ch === "'") { piece = tail < sl ? strSlice(subject, tail, sl) : ""; }
			else if (ch === "<") {
				var close = groups === undefined ? -1 : strIndexOf(template, ">", d + 2);
				if (close < 0) {
					piece = "$<";
				} else {
					var v = groups[strSlice(template, d + 2, close)];
					piece = v === undefined ? "" : StringCtor(v);
					i = close + 1;
				}
			} else {
				var index = 0, j = d + 1, lim = min(j + 2, tl);
				for (; j < lim; j++) {
					var c = strCharCodeAt(template, j);
					if (c < 48 || c > 57) { break; }
					var m = index * 10 + (c - 48);
					if (m >= numCaps) { break; }
					index = m;
				}
				if (index > 0) {
					piece = caps[index] === undefined ? "" : caps[index];
					i = j;
				} else {
					piece = "$" + ch;
				}
			}
			add(piece.length);
			arrayPush(out, piece);
		}
		return apply(origJoin, out, [""]);
	}

	// concat converts each argument once.
	var origConcat = SP.concat, origReplace = SP.replace, origReplaceAll = SP.replaceAll;
	defineProperty(SP, "concat", { writable: true, configurable: true, enumerable: false,
		value: function concat() {
			var head = StringCtor(this), strs = [], total = head.length;
			for (var i = 0; i < arguments.length; i++) {
				var str = StringCtor(arguments[i]);
				total += str.length;
				cap("concat", total);
				arrayPush(strs, str);
			}
			return apply(origConcat, head, strs);
		} });
	defineProperty(SP, "replace", { writable: true, configurable: true, enumerable: false,
		value: function replace(searchValue, replaceValue) {
			return stringReplace("replace", origReplace, false, this, searchValue, replaceValue);
		} });
	defineProperty(SP, "replaceAll", { writable: true, configurable: true, enumerable: false,
		value: function replaceAll(searchValue, replaceValue) {
			return stringReplace("replaceAll", origReplaceAll, true, this, searchValue, replaceValue);
		} });

	// Array, ArrayBuffer and the typed arrays: functions (not Proxies, which
	// goja's instanceof refuses) that check the length and construct the
	// real constructor; they share its prototype and statics, so instanceof,
	// subclassing and species keep working.
	var ownKeys = Reflect.ownKeys, getOwn = Object.getOwnPropertyDescriptor, setPrototypeOf = Object.setPrototypeOf;
	function capConstructor(name, needsNew, check) {
		var Orig = g[name];
		if (typeof Orig !== "function") { return; }
		var Capped = function () {
			if (needsNew && new.target === undefined) { throw new TypeErrorCtor("Constructor " + name + " requires 'new'"); }
			check(arguments);
			return construct(Orig, arguments, new.target === undefined ? Orig : new.target);
		};
		var keys = ownKeys(Orig);
		for (var i = 0; i < keys.length; i++) {
			if (keys[i] !== "length" && keys[i] !== "name") { defineProperty(Capped, keys[i], getOwn(Orig, keys[i])); }
		}
		defineProperty(Capped, "name", { value: name, configurable: true });
		setPrototypeOf(Capped, getPrototypeOf(Orig)); // inherited statics (%TypedArray%.from/of)
		defineProperty(g, name, { value: Capped, writable: true, enumerable: false, configurable: true });
		defineProperty(Orig.prototype, "constructor", { value: Capped, writable: true, enumerable: false, configurable: true });
	}
	function lengthArg(what, perElement) {
		return function (args) {
			if (args.length >= 1 && typeof args[0] === "number") { cap(what, args[0] * perElement); }
		};
	}
	capConstructor("Array", false, function (args) {
		if (args.length === 1 && typeof args[0] === "number") { cap("Array", args[0]); }
	});
	capConstructor("ArrayBuffer", true, lengthArg("ArrayBuffer", 1));
	var typed = ["Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array",
		"Uint32Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array"];
	var TypedProto = getPrototypeOf(Int8Array.prototype);
	guarded(TypedProto, "sort", function (arr, a) {
		if (a[0] === undefined && arr.length > maxSort) {
			throw new RangeErrorCtor("sort: arrays longer than " + maxSort + " need a comparator function");
		}
	});
	for (var t = 0; t < typed.length; t++) { capConstructor(typed[t], true, lengthArg(typed[t], 1)); }
	var typedLength = uncurry(Object.getOwnPropertyDescriptor(TypedProto, "length").get); // throws for a non-typed array
	defineProperty(TypedProto, "toLocaleString", { writable: true, configurable: true, enumerable: false,
		value: function toLocaleString() { return localeJoin(this, typedLength(this), arguments); } });

	var stringify = JSON.stringify;
	// propertyList is JSON.stringify's array replacer as the spec builds it:
	// strings, numbers and String/Number objects, in order, without repeats.
	function propertyList(replacer) {
		var list = [];
		for (var i = 0; i < toLen(replacer.length); i++) {
			var item = replacer[i], key;
			if (typeof item === "string") { key = item; }
			else if (typeof item === "number") { key = StringCtor(item); }
			else if (item !== null && typeof item === "object") {
				var tag = objectToString(item);
				if (tag === "[object String]" || tag === "[object Number]") { key = StringCtor(item); }
			}
			if (key !== undefined && !arrayIncludes(list, key)) { arrayPush(list, key); }
		}
		return list;
	}
	// pick copies the listed keys of a plain object, in list order.
	function pick(val, list) {
		var o = {};
		for (var i = 0; i < list.length; i++) {
			defineProperty(o, list[i], { value: val[list[i]], writable: true, enumerable: true, configurable: true });
		}
		return o;
	}
	// gapLength bounds the indent JSON.stringify uses for space: a number or
	// string (at most 10), a Number or String object (counted as 10: reading
	// its value would run its valueOf twice); any other value means none.
	function gapLength(space) {
		if (typeof space === "number") { var n = floor(space); return n > 10 ? 10 : (n > 0 ? n : 0); }
		if (typeof space === "string") { return min(space.length, 10); }
		var c = space !== null && typeof space === "object" ? classOf(space) : "";
		return c === "Number" || c === "String" ? 10 : 0;
	}
	defineProperty(JSON, "stringify", { writable: true, configurable: true, enumerable: false,
		value: function stringify_(value, replacer, space) {
			var depths = new WeakMapCtor();
			var userFn = typeof replacer === "function" ? replacer : null;
			var list = userFn === null && isArray(replacer) ? propertyList(replacer) : null;
			var gap = gapLength(space), size = 0;
			function guard(key, val) {
				var d = wmGet(depths, this);
				if (d === undefined) { d = 0; }
				if (userFn !== null) { val = apply(userFn, this, [key, val]); }
				// size: about what stringify writes for this value — the
				// value (an object or array: its brackets), the key in an
				// object, a separator and the indent.
				var t = typeof val, n = 0;
				if (t === "string") { n = quotedLength(val); }
				else if (t === "number") { n = StringCtor(val).length; }
				else if (t === "boolean") { n = 5; }
				else if (val === null) { n = 4; }
				else if (t === "object") {
					if (d + 1 > maxDepth) { limit("JSON.stringify: nesting deeper than " + maxDepth); }
					if (list !== null && !isArray(val)) { val = pick(val, list); }
					wmSet(depths, val, d + 1);
					// a String object: its own fixed length, each unit escaped at worst
					n = classOf(val) === "String" ? val.length * 6 + 2 : 2;
				}
				if (d > 0 && !isArray(this)) { n += quotedLength(key) + 1; }
				size += n + 1 + gap * d;
				if (size > maxAlloc) { cap("JSON.stringify", size); }
				return val;
			}
			return stringify(value, guard, space);
		} });

	// JSON.parse refuses text nested deeper than maxDepth before goja parses
	// it; with a reviver, the walk runs as JS (the reviver can graft deeper
	// values onto what it walks).
	var origParse = JSON.parse;
	function internalize(holder, name, reviver, level) {
		var val = holder[name];
		if (val !== null && typeof val === "object") {
			if (level >= maxDepth) { limit("JSON.parse: the reviver walked deeper than " + maxDepth + " levels"); }
			var keys = isArray(val) ? null : objectKeys(val);
			var len = keys === null ? toLen(val.length) : keys.length;
			for (var i = 0; i < len; i++) {
				var k = keys === null ? StringCtor(i) : keys[i];
				var nv = internalize(val, k, reviver, level + 1);
				if (nv === undefined) { reflectDelete(val, k); } else { reflectDefine(val, k, dataProperty(nv)); }
			}
		}
		return apply(reviver, holder, [name, val]);
	}
	defineProperty(JSON, "parse", { writable: true, configurable: true, enumerable: false,
		value: function parse(text, reviver) {
			var str = StringCtor(text);
			if (jsonNestsDeeper(str)) { limit("JSON.parse: the text is nested deeper than " + maxDepth + " levels"); }
			if (typeof reviver !== "function") { return apply(origParse, JSON, [str, reviver]); }
			var root = {};
			defineProperty(root, "", dataProperty(apply(origParse, JSON, [str])));
			return internalize(root, "", reviver, 0);
		} });

	var RP = RegExp.prototype;
	function timed(key) {
		var orig = RP[key], counts = key === Symbol.replace;
		// Fixed in place: a script can neither remove the timing nor reach
		// goja paths that misbehave without exec (a deleted exec panics).
		// @@replace also counts what it inserts (replaceArg).
		defineProperty(RP, key, { writable: false, configurable: false, enumerable: false,
			value: function () {
				var args = arguments;
				if (counts) {
					var str = StringCtor(arguments[0]);
					args = [str, replaceArg("replace", str, arguments[1], false)];
				}
				var t0 = now();
				var out = apply(orig, this, args);
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
	nestsDeeper := func(call goja.FunctionCall) goja.Value {
		return s.rt.ToValue(jsonNestsDeeper(call.Argument(0).String(), MaxJSONDepth))
	}
	quoted := func(call goja.FunctionCall) goja.Value {
		str, _ := call.Argument(0).(goja.String)
		return s.rt.ToValue(jsonQuotedLength(str))
	}
	// classOf: an object's class ("String", "Number", "RegExp", …), "" for
	// anything else; no script code runs to tell.
	classOf := func(call goja.FunctionCall) goja.Value {
		if obj, ok := call.Argument(0).(*goja.Object); ok {
			return s.rt.ToValue(obj.ClassName())
		}
		return s.rt.ToValue("")
	}
	nv, err := lock(goja.Undefined(), s.rt.GlobalObject(), s.rt.ToValue(MaxBuiltinAlloc), s.rt.ToValue(MaxJSONDepth),
		s.rt.ToValue(RegexpMatchTimeout.Milliseconds()), s.rt.ToValue(MaxDefaultSortLength),
		s.rt.ToValue(nestsDeeper), s.rt.ToValue(quoted), s.rt.ToValue(classOf))
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

// jsonQuotedLength is the length, in UTF-16 units, of str as JSON.stringify
// writes it: quotes, `\"` and `\\`, the short escapes, `\u00XX` for other
// control characters and `\uXXXX` for a lone surrogate (a nil str is 2).
func jsonQuotedLength(str goja.String) int {
	if str == nil {
		return 2
	}
	n, l := 2, str.Length()
	for i := 0; i < l; i++ {
		c := str.CharAt(i)
		switch {
		case c == '"' || c == '\\' || c == '\b' || c == '\t' || c == '\n' || c == '\f' || c == '\r':
			n += 2
		case c < 0x20:
			n += 6
		case utf16.IsSurrogate(rune(c)):
			if c < 0xDC00 && i+1 < l && str.CharAt(i+1) >= 0xDC00 && str.CharAt(i+1) <= 0xDFFF {
				n += 2 // a pair, written as is
				i++
			} else {
				n += 6
			}
		default:
			n++
		}
	}
	return n
}

// scanState is what jsonNestsDeeper expects next.
type scanState int

const (
	scanValue        scanState = iota // any value
	scanValueOrClose                  // a value or "]" (just after "[")
	scanKey                           // a key string
	scanKeyOrClose                    // a key or "}" (just after "{")
	scanColon                         // ":" after a key
	scanCommaOrClose                  // "," or the closing bracket
	scanDone                          // the top-level value ended
)

// jsonNestsDeeper reports whether JSON text opens more than limit arrays or
// objects inside each other before its first syntax error. goja's parser
// recurses once per "[" or "{" it accepts and stops at the first error, so it
// never recurses deeper than this count. The scan is never stricter than
// goja (numbers and string escapes are only skimmed), so it cannot stop
// before goja does; text that is not JSON from its first character (a note
// followed by brackets) counts nothing and gets goja's SyntaxError.
func jsonNestsDeeper(text string, limit int) bool {
	var stack []byte
	state := scanValue
	for i := 0; ; {
		for i < len(text) && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r') {
			i++
		}
		if i >= len(text) {
			return false
		}
		c := text[i]
		switch state {
		case scanValue, scanValueOrClose:
			if c == ']' && state == scanValueOrClose {
				stack = stack[:len(stack)-1]
				i++
				state = jsonAfterValue(stack)
				continue
			}
			if c == '[' || c == '{' {
				if stack = append(stack, c); len(stack) > limit {
					return true
				}
				i++
				state = scanValueOrClose
				if c == '{' {
					state = scanKeyOrClose
				}
				continue
			}
			if i = jsonScalarEnd(text, i); i < 0 {
				return false
			}
			state = jsonAfterValue(stack)
		case scanKey, scanKeyOrClose:
			if c == '}' && state == scanKeyOrClose {
				stack = stack[:len(stack)-1]
				i++
				state = jsonAfterValue(stack)
				continue
			}
			if c != '"' {
				return false
			}
			if i = jsonStringEnd(text, i); i < 0 {
				return false
			}
			state = scanColon
		case scanColon:
			if c != ':' {
				return false
			}
			i++
			state = scanValue
		case scanCommaOrClose:
			top := stack[len(stack)-1]
			switch {
			case c == ',' && top == '[':
				state = scanValue
			case c == ',':
				state = scanKey
			case c == ']' && top == '[', c == '}' && top == '{':
				stack = stack[:len(stack)-1]
				state = jsonAfterValue(stack)
			default:
				return false
			}
			i++
		default: // scanDone: goja reads one more token and fails, without recursing
			return false
		}
	}
}

func jsonAfterValue(stack []byte) scanState {
	if len(stack) == 0 {
		return scanDone
	}
	return scanCommaOrClose
}

// jsonScalarEnd returns the index after the string, number or literal at i,
// or -1 when there is none.
func jsonScalarEnd(text string, i int) int {
	c := text[i]
	switch {
	case c == '"':
		return jsonStringEnd(text, i)
	case c == '-' || (c >= '0' && c <= '9'):
		j := i + 1
		for j < len(text) && strings.IndexByte("0123456789.eE+-", text[j]) >= 0 {
			j++
		}
		return j
	}
	for _, lit := range []string{"true", "false", "null"} {
		if strings.HasPrefix(text[i:], lit) {
			return i + len(lit)
		}
	}
	return -1
}

// jsonStringEnd returns the index after the string that opens at i, or -1
// when it never closes.
func jsonStringEnd(text string, i int) int {
	for j := i + 1; j < len(text); j++ {
		switch text[j] {
		case '\\':
			j++
		case '"':
			return j + 1
		}
	}
	return -1
}
