package com.example.store;

import java.util.HashMap;
import java.util.Map;

/** Something that can be stored. */
interface Storable {
    /** The key this value is stored under. */
    String key();
}

/**
 * A key-value store.
 * Keeps entries in a map.
 */
@Deprecated
public final class Sample implements Storable {
    /** The largest size a store holds. */
    public static final int MAX_SIZE = 64;

    private final Map<String, String> entries = new HashMap<>();

    /** Builds an empty store. */
    public Sample() {
    }

    // A plain comment is not a doc.
    @Override
    public String key() {
        Runnable local = () -> {};
        return "store";
    }

    /** Adds a value under a key. */
    public <T> void add(String key, T value) {
        entries.put(key, String.valueOf(value));
    }

    /** Shape of a value. */
    enum Shape {
        CIRCLE,
        SQUARE;

        int sides() {
            return 0;
        }
    }

    /** A point in the plane. */
    record Point(int x, int y) {
        Point {
        }
    }

    /** Marks a test. */
    @interface Marker {
        String value() default "";
    }
}
