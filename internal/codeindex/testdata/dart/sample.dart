// A tiny Dart fixture for the full grammar set.

/// The largest size a store holds.
const maxSize = 64;

/// Something that can be stored.
abstract class Storable {
  /// The key this value is stored under.
  String get key;
}

/// A key-value store.
class Store<T> implements Storable {
  /// The entries, by key.
  final Map<String, T> entries = {};

  final String name;

  /// Builds a named store.
  Store(this.name);

  factory Store.empty() => Store('empty');

  // A plain comment is not a doc.
  @override
  String get key => name;

  /// Adds a value under a key.
  void add(String key, T value) {
    final local = value;
    entries[key] = local;
  }
}

/// Shape of a value.
enum Shape { circle, square }

/// Counts what it touches.
mixin Counts {
  int count = 0;
}

/// Helpers on strings.
extension Shout on String {
  String shout() => toUpperCase();
}

typedef Id = String;

/// Doubles a number.
int twice(int n) {
  return n * 2;
}
