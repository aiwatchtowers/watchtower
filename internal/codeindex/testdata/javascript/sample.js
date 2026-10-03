// A tiny JavaScript fixture for the full grammar set.

/** The largest size a store holds. */
export const MAX_SIZE = 64;

let counter = 0;

/**
 * A key-value store.
 * Keeps entries in a map.
 */
export class Store {
  /** The entries, by key. */
  entries = new Map();

  constructor() {
    this.entries.clear();
  }

  /** Adds a value under a key. */
  add(key, value) {
    this.entries.set(key, value);
  }

  static empty() {
    return new Store();
  }

  get size() {
    return this.entries.size;
  }
}

// A plain comment is not a doc.
function helper(a, b) {
  function inner() {}
  return a + b;
}

/** Doubles a number. */
const double = (n) => n * 2;

export default function* ids() {
  yield 1;
}

const api = {
  /** Fetches a thing. */
  fetch: async function (id) {
    return id;
  },
  stop() {},
};

module.exports.render = function render(view) {
  return view;
};
