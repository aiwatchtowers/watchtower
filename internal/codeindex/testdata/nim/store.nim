## A key-value store.

import std/tables

const
  MaxSize* = 64 ## The largest size a store holds.
  Greeting = "hello"

let defaultName* = "store"

var counter = 0

type
  Shape* = enum ## How a store is drawn.
    circle, square

  Store*[T] = object
    ## A key-value store.
    name*: string ## The store's name.
    entries: Table[string, T]

  Storable* = concept x
    x.key is string

  Id* = distinct string

  Node = ref object of RootObj
    next: Node

  Pair = tuple[key: string, value: int]

proc newStore*[T](name: string): Store[T] =
  ## Builds an empty store.
  result = Store[T](name: name)

# Adds a value under a key.
proc add*[T](s: var Store[T], key: string, value: T) =
  let local = key
  proc inner() = discard
  s.entries[local] = value

func twice*(n: int): int = n * 2

method area(n: Node): float {.base.} = 0.0

iterator items*[T](s: Store[T]): T =
  for v in s.entries.values: yield v

template withStore*(body: untyped) =
  body

macro trace*(ex: untyped): untyped =
  result = ex

converter toInt(s: Shape): int = ord(s)
