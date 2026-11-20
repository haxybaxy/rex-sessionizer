-- An in-memory stand-in for the `rex` global that init.lua talks to:
-- sessions, apps, directories and floating layers, with every call recorded
-- in order so tests can check what the plugin asked Rex to do.
--
--   local fake = require("fake_rex").install()
--   fake:reset()
--   local id = fake:add_session("home")
--
-- rex.ui.pick answers with what fake:answer queued. rex.exec answers
-- `test -d` from fake.dirs, and any other command from fake.run(argv, opts).

local Fake = {}
Fake.__index = Fake

-- Put the fake in place of the rex global and of os.getenv's view of the
-- environment. Returns the fake.
function Fake.install()
  local fake = setmetatable({}, Fake)
  fake.env = {}

  local getenv = os.getenv
  os.getenv = function(name)
    if fake.env[name] ~= nil then return fake.env[name] or nil end
    return getenv(name)
  end

  rex = fake:api()
  fake:reset()
  return fake
end

-- Forget every session, app, call and answer from the previous test.
function Fake:reset()
  self.dirs = {}         -- [path] = true for each directory that exists
  self.sessions = {}     -- { session_id, label } in creation order
  self.apps = {}         -- { client_id, attached = { [session_id] = true }, refuses = message }
  self.calls = {}        -- every call, in order: { name = ..., args = ... }
  self.logs = {}         -- { level, message }
  self.actions = {}      -- [name] = the table given to rex.action
  self.answers = {}      -- what rex.ui.pick answers, in order: { value, why, detail }
  self.run = nil         -- function(argv, opts) -> rex.exec's result, for commands other than test -d
  self.next_id = 0
  rex.ui = self.ui       -- a test may set it to nil, as in a Rex without prompts
end

-- Queue rex.ui.pick's next answer: an item's id, or nil with a reason such
-- as "cancelled". Unqueued questions are cancelled.
function Fake:answer(value, why, detail)
  self.answers[#self.answers + 1] = { value = value, why = why, detail = detail }
end

function Fake:new_id(kind)
  self.next_id = self.next_id + 1
  return kind .. ":" .. self.next_id
end

-- Add a session as if someone made it outside the plugin. Returns its ID.
function Fake:add_session(label)
  local id = self:new_id("session")
  self.sessions[#self.sessions + 1] = { session_id = id, label = label }
  return id
end

function Fake:session(id)
  for _, s in ipairs(self.sessions) do
    if s.session_id == id then return s end
  end
  return nil
end

-- Add a connected app, attached to the given sessions. refuses, when set, is
-- the error it answers client.perform with, as with Remote Control off.
function Fake:add_app(attached, refuses)
  local app = { client_id = self:new_id("client"), attached = {}, refuses = refuses }
  for _, id in ipairs(attached or {}) do app.attached[id] = true end
  self.apps[#self.apps + 1] = app
  return app
end

function Fake:record(name, args)
  self.calls[#self.calls + 1] = { name = name, args = args }
end

-- The recorded calls with this name, in order.
function Fake:calls_to(name)
  local found = {}
  for _, call in ipairs(self.calls) do
    if call.name == name then found[#found + 1] = call end
  end
  return found
end

-- The argv of each command other than test -d, in order.
function Fake:commands()
  local found = {}
  for _, call in ipairs(self:calls_to("exec")) do
    if call.args.argv[1] ~= "test" then found[#found + 1] = call.args end
  end
  return found
end

-- The sessions the app was asked to show, in order, however it was asked.
function Fake:selected()
  local ids = {}
  for _, call in ipairs(self.calls) do
    if (call.name == "client.queue" or call.name == "client.perform")
        and call.args.action == "session.select" then
      ids[#ids + 1] = call.args.args.session_id
    end
  end
  return ids
end

function Fake:warnings()
  local found = {}
  for _, log in ipairs(self.logs) do
    if log.level == "warn" then found[#found + 1] = log.message end
  end
  return found
end

-- Server methods, called as rex.call(method, args).
local methods = {}

function methods.session_list(fake)
  local list = {}
  for _, s in ipairs(fake.sessions) do list[#list + 1] = { session_id = s.session_id, label = s.label } end
  return { sessions = list }
end

function methods.session_create(fake, args)
  return { session_id = fake:add_session(args.label) }
end

function methods.client_list(fake, args)
  local clients = {}
  for _, app in ipairs(fake.apps) do
    if args.session_id == nil or app.attached[args.session_id] then
      clients[#clients + 1] = { client_id = app.client_id }
    end
  end
  return { clients = clients }
end

function methods.client_perform(fake, args)
  for _, app in ipairs(fake.apps) do
    if app.client_id == args.client_id then
      if app.refuses then return nil, app.refuses end
      return {}
    end
  end
  return nil, "client_not_found"
end

-- The rex table init.lua sees.
function Fake:api()
  local fake = self
  fake.ui = {
    pick = function(prompt)
      fake:record("ui.pick", prompt)
      local answer = table.remove(fake.answers, 1) or { why = "cancelled" }
      return answer.value, answer.why, answer.detail
    end,
  }
  return {
    log = function(level, message)
      fake.logs[#fake.logs + 1] = { level = level, message = message }
    end,

    ui = fake.ui,

    exec = function(argv, opts)
      fake:record("exec", { argv = argv, opts = opts })
      if argv[1] == "test" and argv[2] == "-d" then return { ok = fake.dirs[argv[3]] == true } end
      if fake.run then return fake.run(argv, opts or {}) end
      return { ok = true, code = 0, stdout = "", stderr = "" }
    end,

    call = function(method, args)
      args = args or {}
      fake:record(method, args)
      local handler = methods[method:gsub("%.", "_")]
      if not handler then return nil, "unknown method " .. method end
      return handler(fake, args)
    end,

    client = {
      queue = function(action, args)
        fake:record("client.queue", { action = action, args = args })
      end,
    },

    session = {
      new_layer = function(args)
        fake:record("session.new_layer", args)
        return { layer_id = fake:new_id("layer") }
      end,
      close_layer = function(args)
        fake:record("session.close_layer", args)
        return {}
      end,
    },

    layout = {
      block = function(block) return { block = block } end,
    },

    action = function(definition)
      fake.actions[definition.name] = definition
    end,
  }
end

return Fake
