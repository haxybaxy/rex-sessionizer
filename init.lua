-- rex-sessionizer: a project picker for Rex, ported from tmux-sessionizer.
--
--   require("rex-sessionizer").setup{ work_dir = "~/work" }
--   rex.bind("ctrl+space>f", "sessionizer")
--
-- The key opens a floating fzf picker over the directories under work_dir.
-- Picking one switches Rex to a session for that directory, creating it with
-- a shell started there when it doesn't exist yet. Sessions are labelled after
-- their directory, so the picker finds the session it created before.
--
-- Actions:
--   sessionizer      Open the picker.
--   sessionizer_go   Switch to the session for a directory:
--                      rex do sessionizer_go path=my-project
--
-- The float runs sessionizer.sh, which hands the pick back with
-- `rex do sessionizer_go`. The app accepts that switch from the CLI only with
-- Remote Control on (Rex → Settings → Rex Server). The action can't wait for
-- the pick itself: the app stops taking input while a key-bound action runs.

local M = {}

M.version = "0.1.0"

M.options = {
  -- The directory whose subdirectories are projects. When the current project
  -- holds only directories, those are offered too; sessionizer.sh has the rules.
  work_dir = "~/work",
  -- Where the picker floats: x, y, width, height as fractions of the window.
  bounds = { 0.15, 0.1, 0.7, 0.8 },
  -- function(name, path) returning the layout for a new session, built with
  -- rex.layout. The default is one shell started in the directory.
  layout = nil,
  -- The picker script. Defaults to sessionizer.sh beside this file.
  script = nil,
}

local SHELL = "com.superlogical.terminal.shell"

local state = { layer_id = nil }

local function fail(message)
  error("sessionizer: " .. message, 0)
end

-- The directory this file is in. Rex names a module's chunk by its absolute
-- path; a relative name is taken from beside the init.lua Rex opened.
local function module_dir()
  local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
  local dir = src:match("^(/.*)/[^/]*$")
  if dir then return dir end
  local cfg = os.getenv("REX_CONFIG")
  local base = cfg and cfg:match("^(.*)/[^/]*$")
    or (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/rex"
  local rel = src:match("^(.*)/[^/]*$")
  return rel and (base .. "/" .. rel) or base
end

local function expand_home(path)
  if path:sub(1, 2) == "~/" then return os.getenv("HOME") .. path:sub(2) end
  return path
end

local function basename(path)
  return (path:gsub("/+$", ""):match("([^/]+)$"))
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_dir(path)
  local r = rex.exec{ "test", "-d", path }
  return r ~= nil and r.ok
end

local function sessions()
  local list, err = rex.call("session.list")
  if list == nil then fail(tostring(err)) end
  return list.sessions or {}
end

local function session_label(session_id)
  for _, s in ipairs(sessions()) do
    if s.session_id == session_id then return s.label end
  end
  return nil
end

local function find_session(label)
  for _, s in ipairs(sessions()) do
    if s.label == label then return s.session_id end
  end
  return nil
end

local function default_layout(name, path)
  return rex.layout.block{ flavor = SHELL, options = { cwd = path } }
end

-- The session for a directory, created if missing. Returns session_id, created.
local function session_for(path)
  local name = basename(path)
  local existing = find_session(name)
  if existing then return existing, false end
  local created, err = rex.call("session.create", {
    label = name,
    initial_windows = { { layout = (M.options.layout or default_layout)(name, path) } },
  })
  if created == nil then fail(tostring(err)) end
  return created.session_id, true
end

-- Ask the Rex app to show a session.
local function show_in_app(ctx, session_id)
  if ctx.origin == "key" or ctx.origin == "palette" then
    -- The app ran this action, so it accepts the request as is.
    rex.client.queue("session.select", { session_id = session_id })
    return
  end
  -- Run from the CLI or a script: ask the app(s) viewing this session. The app
  -- accepts this only with Remote Control on.
  local apps = rex.call("client.list", { kinds = { "app" }, session_id = ctx.session_id })
  if apps == nil or #(apps.clients or {}) == 0 then
    apps = rex.call("client.list", { kinds = { "app" } })
  end
  local last_err
  for _, c in ipairs(apps and apps.clients or {}) do
    local _, err = rex.call("client.perform", {
      client_id = c.client_id,
      action    = "session.select",
      args      = { session_id = session_id },
      origin    = ctx.origin,
    })
    if err == nil then return end
    last_err = err
  end
  error(last_err or "no Rex app is connected", 0)
end

local function close_picker()
  if state.layer_id then
    rex.session.close_layer{ layer_id = state.layer_id }
    state.layer_id = nil
  end
end

-- Open a floating terminal running command; a picker already open is replaced.
local function open_picker(command)
  close_picker()
  local layer, err = rex.session.new_layer{
    bounds = M.options.bounds,
    focus  = true,
    layout = {
      block = {
        flavor  = SHELL,
        label   = "sessionizer",
        options = { command = command },
      },
    },
  }
  if err ~= nil then fail(tostring(err)) end
  state.layer_id = layer.layer_id
  return layer
end

-- An absolute path, ~/path, or a name under work_dir (or under home), as an
-- absolute project directory.
local function resolve_path(path)
  path = expand_home(trim(path or ""))
  if path == "" then fail("no path given") end
  local candidates = { path }
  if path:sub(1, 1) ~= "/" then
    candidates = { M.options.work_dir .. "/" .. path, os.getenv("HOME") .. "/" .. path }
  end
  for _, p in ipairs(candidates) do
    if is_dir(p) then return p end
  end
  fail("not a directory: " .. path)
end

-- Switch the app to the session for a directory, creating it if needed.
function M.go(ctx, path)
  path = resolve_path(path)
  local session_id, created = session_for(path)
  local ok, err = pcall(show_in_app, ctx, session_id)
  if not ok then
    fail("session \"" .. basename(path) .. "\" is ready, but the app would not show it: " .. tostring(err))
  end
  return { session_id = session_id, path = path, created = created }
end

-- Open the picker over the session the action runs in.
function M.open(ctx)
  local layer = open_picker{
    M.options.script,
    "--work-dir", M.options.work_dir,
    "--current",  session_label(ctx.session_id) or "",
  }
  return { layer_id = layer.layer_id }
end

function M.setup(opts)
  local known = { layout = true, script = true }
  for k in pairs(M.options) do known[k] = true end
  for k, v in pairs(opts or {}) do
    if known[k] then
      M.options[k] = v
    else
      rex.log("warn", "rex-sessionizer: ignoring unknown option " .. tostring(k))
    end
  end
  M.options.work_dir = (expand_home(M.options.work_dir):gsub("/+$", ""))
  M.options.script   = expand_home(M.options.script or (module_dir() .. "/sessionizer.sh"))

  rex.action{
    name        = "sessionizer",
    title       = "Switch Project…",
    description = "Pick a directory under " .. M.options.work_dir .. " and switch to its session.",
    category    = "Session",
    keywords    = "project work directory tmux sessionizer",
    run = function(ctx) return M.open(ctx) end,
  }

  rex.action{
    name        = "sessionizer_go",
    title       = "Go to Project",
    description = "Switch to the session for a directory under " .. M.options.work_dir .. ", creating it if needed.",
    category    = "Session",
    args        = { path = "string" },
    run = function(ctx, args) return M.go(ctx, args.path) end,
  }

  return M
end

return M
