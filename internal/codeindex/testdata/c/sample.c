/* A tiny C fixture for the full grammar set. */

#include <stdlib.h>

/** The largest size a store holds. */
#define MAX_SIZE 64

#define SQUARE(x) ((x) * (x))

/** A key-value store. */
struct store {
    /** The number of entries. */
    size_t len;
    char **keys;
};

/// Shape of a value.
enum shape { CIRCLE, SQUARE_SHAPE };

union bits {
    unsigned int i;
    float f;
};

/** An id. */
typedef unsigned long id_t;

typedef struct {
    int x, y;
} point;

static const int capacity = 8;

int counter;

/** Builds an empty store. */
struct store *store_new(void);

// A plain comment is not a doc.
static int helper(int a, int b)
{
    int local = a + b;
    return local;
}

/** Returns the store's first key. */
char *store_first(const struct store *s)
{
    return s->keys[0];
}
