// A tiny Scala fixture for the full grammar set.
package acme.store

/** The largest size a store holds. */
val MaxSize: Int = 64

/** Something that can be stored. */
trait Storable {
  /** The key this value is stored under. */
  def key: String
}

/** A key-value store. */
final class Store[T](val name: String) extends Storable {
  private var entries: Map[String, T] = Map.empty

  // A plain comment is not a doc.
  def key: String = name

  /** Adds a value under a key. */
  def add(key: String, value: T): Unit = {
    val local = 1
    entries = entries.updated(key, value)
  }
}

/** Builds stores. */
object Store {
  def empty[T]: Store[T] = new Store[T]("empty")
}

/** Shape of a value. */
enum Shape {
  case Circle, Square
}

/** A point in the plane. */
case class Point(x: Int, y: Int)

type Id = String

/** Doubles a number. */
def double(n: Int): Int = n * 2
