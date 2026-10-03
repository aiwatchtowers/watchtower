module Sample exposing (Shape(..), Store, add, empty, maxSize)

{-| A tiny Elm fixture for the full grammar set.
-}


{-| The largest size a store holds.
-}
maxSize : Int
maxSize =
    64


{-| A key-value store.
-}
type alias Store =
    { entries : List ( String, Int )
    , name : String
    }


{-| Shape of a value.
-}
type Shape
    = Circle
    | Square


{-| Builds an empty store.
-}
empty : Store
empty =
    { entries = [], name = "empty" }


-- A plain comment is not a doc.
add : String -> Int -> Store -> Store
add key value store =
    let
        local =
            ( key, value )
    in
    { store | entries = local :: store.entries }


port send : String -> Cmd msg
