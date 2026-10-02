{-# LANGUAGE OverloadedStrings #-}
-- | A key-value store.
module Acme.Store
  ( Store (..)
  , empty
  ) where

import qualified Data.Map as Map

-- | The largest size a store holds.
maxSize :: Int
maxSize = 64

-- | A key-value store.
data Store k v = Store
  { entries :: Map.Map k v
  , name :: String
  }

-- How a store is drawn.
data Shape = Circle | Square Int
  deriving (Show, Eq)

newtype Key = Key String

type Id = String

-- | Something that can be stored.
class Storable a where
  -- | The key a value is stored under.
  key :: a -> String
  label :: a -> String
  label = key

instance Storable Key where
  key (Key k) = k

-- | Builds an empty store.
empty :: String -> Store k v
empty n = Store {entries = Map.empty, name = n}

add :: Ord k => k -> v -> Store k v -> Store k v
add k v s = s {entries = Map.insert k v (entries s)}
  where
    local = k

twice :: Int -> Int
twice 0 = 0
twice n = n * 2

-- | Counts the entries.
size :: Store k v -> Int
size = Map.size . entries
