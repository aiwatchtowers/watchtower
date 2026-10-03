(* A tiny OCaml fixture for the full grammar set. *)

(** The largest size a store holds. *)
let max_size = 64

(** A key-value store. *)
type 'a store = {
  entries : (string * 'a) list;  (** The entries. *)
  name : string;
}

(** Shape of a value. *)
type shape = Circle | Square

(** Builds an empty store. *)
let empty name = { entries = []; name }

(* A plain comment is not a doc. *)
let add key value store =
  let local = (key, value) in
  { store with entries = local :: store.entries }

(** Something that can be stored. *)
module type STORABLE = sig
  val key : unit -> string
end

(** Inner helpers. *)
module Helpers = struct
  (** Assists. *)
  let assist () = ()
end

(** A counter object. *)
class counter = object
  val mutable count = 0
  method incr = count <- count + 1
end

external now : unit -> float = "caml_now"
