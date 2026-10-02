package acme.store

import kotlin.math.max

/** The largest size a store holds. */
const val MAX_SIZE = 64

/** A key-value store. */
data class Entry(val key: String, val value: Int)

// Shapes a store can draw.
enum class Shape {
    CIRCLE,
    SQUARE;

    fun sides(): Int = if (this == CIRCLE) 0 else 4
}

/** Something that can be stored. */
interface Storable {
    val key: String
    fun describe(): String
}

/**
 * Keeps entries by key.
 * Not thread-safe.
 */
class Store<T : Storable>(private val name: String) : Storable {
    override val key: String = name
    var count: Int = 0
        private set

    fun add(entry: T) {
        val local = entry.key
        count = max(count, local.length)
    }

    override fun describe(): String = "store $name"

    companion object {
        fun empty(): Store<Entry> = TODO()
    }
}

/** A single shared registry. */
object Registry {
    val stores = mutableListOf<String>()

    fun register(name: String) {
        fun inner() = name
        stores.add(inner())
    }
}

/** Doubles a number. */
fun double(x: Int): Int = x * 2

/** The last character of a string. */
fun String.lastChar(): Char = this[length - 1]

typealias Id = String

var counter = 0

sealed interface Event
