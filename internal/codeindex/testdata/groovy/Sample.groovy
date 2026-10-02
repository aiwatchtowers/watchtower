package acme.store

import groovy.transform.CompileStatic

/** The largest size a store holds. */
final int MAX_SIZE = 64

/** Something that can be stored. */
interface Storable {
    String key()
}

// Shapes a store draws.
enum Shape {
    CIRCLE, SQUARE
}

/**
 * Keeps entries by key.
 */
@CompileStatic
class Store implements Storable {
    static final int CAPACITY = 16
    private Map<String, Object> entries = [:]
    String name

    Store(String name) {
        this.name = name
    }

    /** Adds a value under a key. */
    void add(String key, Object value) {
        def local = key.trim()
        entries[local] = value
    }

    String key() { name }

    static Store empty() {
        new Store('empty')
    }
}

/** Doubles a number. */
def twice(int n) {
    n * 2
}

def helper = { a -> a + 1 }

trait Named {
    String label() { 'named' }
}

println twice(2)
