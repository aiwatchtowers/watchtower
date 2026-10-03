-- A tiny Lua fixture for the full grammar set.

local M = {}

--- The largest size a store holds.
M.MAX_SIZE = 64

--- Builds an empty store.
---@return table a store
function M.new()
  local function inner() end
  return setmetatable({}, M)
end

--- Adds a value under a key.
function M:add(key, value)
  self[key] = value
end

-- A plain comment is not a doc.
local function helper(a, b)
  return a + b
end

--- Doubles a number.
function double(n)
  return n * 2
end

local handlers = {
  --- Starts a run.
  start = function() end,
}

M.stop = function() end

return M
