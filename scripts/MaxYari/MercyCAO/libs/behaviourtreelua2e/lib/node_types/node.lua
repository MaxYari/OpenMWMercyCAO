local _PACKAGE = (...):match("^(.+)[%./][^%./]+"):gsub("[%./]?node_types", "")
local class    = require(_PACKAGE .. '/middleclass')
local Node     = class('Node')
local g        = _BehaviourTreeGlobals

local function noop() end
local API_DEFAULTS = {
  -- Functions provided by the module user
  start = noop,
  run = noop,
  finish = noop,
  shouldRun = noop,    --Interrupts only
  registered = noop,   --Interrupts only
  deregistered = noop, --Interrupts only
}

function Node:initialize(config)
  self._initData = config or {}
  if not config.properties then config.properties = {} end
  self.properties = self._initData.properties
  self.p = self.properties
  self.name = self._initData.name or "NoName"
  self.finished = true

  -- Api object is built once and reused on every start, so starting a node allocates nothing.
  -- Defaults and config fields are read through __index, fields set on it at runtime are wiped in initApiObject.
  local base = {}
  for k, v in pairs(API_DEFAULTS) do base[k] = v end
  for k, v in pairs(self._initData) do base[k] = v end
  self.api = setmetatable({}, { __index = base })

  -- Status reporters are bound once and assigned to the api as needed
  local node = self
  self._apiSuccess = function() node:success() end
  self._apiFail = function() node:fail() end
  self._apiRunning = function() node:running() end
end

-- All the node:fn functions can be overriden in child classes to implement new node types. If you want to call the
-- original child function from the override - do Parent.fn(self, otherArguments)
function Node:initApiObject()
  -- Api is wiped clean after every start: only fields set at runtime live in the table itself, config stays reachable through __index
  local api = self.api
  for k in pairs(api) do api[k] = nil end
end

function Node:registerApiStatusFunctions()
  self.api.success = self._apiSuccess
  self.api.fail = self._apiFail
  -- running is as needed inside the run() function
end

function Node:deregisterApiStatusFunctions()
  if not self.api then return end
  self.api.success = nil
  self.api.fail = nil
  self.api.running = nil
end

function Node:start()
  if self.tree.debugLevel >= 1 then self.tree:print(self.name .. " STARTED") end
  -- Api is repopulated anew after every start
  self:initApiObject()
  self:registerApiStatusFunctions()
  self.finished = false

  self.tree:setActiveNode(self)

  self.api:start(self.tree.stateObject)
end

function Node:run()
  if self.tree.debugLevel >= 1 then self.tree:printLazy(self.name .. " RUN") end
  self.api.running = self._apiRunning
  self.api:run(self.tree.stateObject)
  self.api.running = nil --deregister so it can not be called outside the run function
end

function Node:abort() -- Should rename to abort
  -- Call user-facing finish callback
  if self.tree.debugLevel >= 1 then self.tree:print(self.name .. " ABORTED") end
  self:finish()
end

-- TASK STATUSES - triggered by the module user, bubble up from childrent to parents
function Node:running()
  if self.finished then
    error(
    "'Running' status was reported on a node after the node was finished. Either an API misuse or a bug. Node: " ..
    tostring(self.name) .. " Tree: " .. tostring(self.tree.name), 2)
  end
end

function Node:success()
  if self.finished then
    error(
    "'Success' status was reported on a node after the node was finished. Either an API misuse or a bug. Node: " ..
    tostring(self.name) .. " Tree: " .. tostring(self.tree.name), 2)
  end
  if self.tree.debugLevel >= 1 then self.tree:print(self.name .. ' SUCCESS') end

  self:finish()
  if self.parentNode then
    self.parentNode:success()
  end
end

function Node:fail()
  if self.finished then
    error(
    "'Fail' status was reported on a node after the node was finished. Either an API misuse or a bug. Node: " ..
    tostring(self.name) .. " Tree: " .. tostring(self.tree.name), 2)
  end
  if self.tree.debugLevel >= 1 then self.tree:print(self.name .. ' FAIL') end

  if self.finished then
    error(
      tostring(self.name) ..
      " node error. Fail state was called after node was finished. This should never happen, the node was probably not implemented properly.",
      2)
  end

  self:finish()
  if self.parentNode then
    self.parentNode:fail()
  end
end

-- Finish is not a task status and shouldn't be used as such, it should only be used for a final cleanup, never to report a status.
function Node:finish()
  if self.tree.debugLevel >= 2 then self.tree:print((self.name or "NONAME_NODE") .. ' FINISH', 2) end

  self:deregisterApiStatusFunctions()
  self.finished = true
  self.tree:removeActiveNode(self)

  self.api:finish(self.tree.stateObject)
end

return Node
