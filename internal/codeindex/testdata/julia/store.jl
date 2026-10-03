"""
A key-value store module.
"""
module Acme

export Store, add!

"The largest size a store holds."
const MAX_SIZE = 64

counter = 0

"""
    Store(name)

A key-value store.
"""
mutable struct Store{T}
    name::String
    entries::Dict{String,T}
end

struct Point
    x::Int
    y::Int
end

abstract type Shape end

primitive type Bits 32 end

@enum Color red green blue

# Adds a value under a key.
function add!(s::Store, key, value)
    local_key = strip(key)
    s.entries[local_key] = value
    return s
end

"Doubles a number."
twice(n) = 2n

macro trace(ex)
    return esc(ex)
end

function Base.length(s::Store)
    inner(x) = x
    return inner(length(s.entries))
end

end # module
