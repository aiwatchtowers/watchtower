(ns acme.store
  "A key-value store."
  (:require [clojure.string :as str]))

;; The largest size a store holds.
(def max-size 64)

(def ^:private greeting
  "The greeting a store prints."
  "hello")

(defonce registry (atom {}))

(defn add
  "Adds a value under a key."
  [store k v]
  (let [local k]
    (assoc store local v)))

(defn- helper [x]
  (letfn [(inner [y] y)]
    (inner x)))

;; Shapes a store draws.
(defmulti area :shape)

(defmethod area :circle [s] 0)

(defmacro with-store
  "Runs body with a store."
  [& body]
  `(do ~@body))

(defprotocol Storable
  "Something that can be stored."
  (key-of [this] "The key a value is stored under."))

(defrecord Entry [k v]
  Storable
  (key-of [_] k))

(deftype Box [value])
