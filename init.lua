-- rex-sessionizer: a project picker for Rex, ported from ThePrimeagen's
-- tmux-sessionizer: https://github.com/theprimeagen/tmux-sessionizer
--
--   require("rex-sessionizer").setup{ work_dir = "~/work" }
--   rex.bind("ctrl+space>f", "sessionizer")
--
-- The key opens a picker over the directories under work_dir: fzf in a float,
-- or Rex's command palette with picker = "native". Picking one switches Rex to
-- a session for that directory, creating it with a shell started there when it
-- doesn't exist yet. Sessions are labelled after their directory, so the
-- picker finds the session it created before.
--
-- Actions:
--   sessionizer      Open the picker.
--   sessionizer_go   Switch to the session for a directory:
--                      rex do sessionizer_go path=my-project
--
-- How the picker hands back:
--   picker = "float", the default: the float runs sessionizer.sh, which picks
--   with fzf and hands the pick back with `rex do sessionizer_go`. The app
--   accepts that switch from the CLI only with Remote Control on (Rex →
--   Settings → Rex Server). The action can't wait for the pick itself: the
--   app stops taking input while a key-bound action runs.
--   picker = "native": the action asks in Rex's command palette with
--   rex.ui.pick, which pauses it until the person answers, and switches
--   itself. It needs no fzf and, run from a key, no Remote Control. The float
--   is used when Rex can't ask in the palette (see The native picker).

local M = {}

M.version = "0.2.0"

M.options = {
  -- The directory whose subdirectories are projects. When the current project
  -- holds only directories, those are offered too; sessionizer.sh has the rules.
  work_dir = "~/work",
  -- Where the picker floats: x, y, width, height as fractions of the window.
  bounds = { 0.15, 0.1, 0.7, 0.8 },
  -- How the picker asks: "float" runs fzf in a floating terminal; "native"
  -- lists in Rex's command palette, and uses the float when Rex can't ask
  -- there.
  picker = "float",
  -- function(name, path) returning the layout for a new session, built with
  -- rex.layout. The default is one shell started in the directory.
  layout = nil,
  -- The picker script. Defaults to sessionizer.sh beside this file.
  script = nil,
}

local SHELL = "com.superlogical.terminal.shell"

-- The values the picker option takes.
local PICKERS = { float = true, native = true }

local state = { layer_id = nil }

local function fail(message)
  error("sessionizer: " .. message, 0)
end

local function warn(message)
  rex.log("warn", "rex-sessionizer: " .. message)
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

-- The first line of a command's error output, to put in a message.
local function first_line(s)
  local line = trim(s or ""):match("^[^\n]*")
  return line ~= "" and line or "no output"
end

-- A path with the home directory as ~, for showing.
local function tilde(path)
  local home = os.getenv("HOME") or ""
  if home ~= "" and (path == home or path:sub(1, #home + 1) == home .. "/") then
    return "~" .. path:sub(#home + 1)
  end
  return path
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

-- The fzf picker, in a float over the session the action runs in.
local function float_pick(ctx)
  local layer = open_picker{
    M.options.script,
    "--work-dir", M.options.work_dir,
    "--current",  session_label(ctx.session_id) or "",
  }
  return { layer_id = layer.layer_id }
end

--------------------------------------------------------------------------------
-- The native picker
--
-- With picker = "native", the picker lists in Rex's command palette with
-- rex.ui.pick, and the action switches to the pick itself. The list comes
-- from `sessionizer.sh --list`, so the float and the palette offer the same
-- directories in the same order. The fzf float is used instead when Rex
-- can't ask in the palette: no Rex app that can show prompts, or a session on
-- another host, where the directories would be listed on the wrong machine.
--------------------------------------------------------------------------------

-- Rex lists at most this many items.
local MAX_ITEMS = 2000

-- Whether this pick happens in the palette.
local function use_native(ctx)
  if M.options.picker ~= "native" or ctx.server ~= nil then return false end
  if rex.ui == nil or rex.ui.pick == nil then
    warn("this Rex can't ask in the command palette; using the float")
    return false
  end
  return true
end

-- Ask in the palette. Returns the answer; nil when the person didn't answer;
-- or nil, true when Rex couldn't ask, and the float should. Never call it
-- inside pcall: Rex can only pause an action outside one.
local function ask(prompt)
  local answer, why, detail = rex.ui.pick(prompt)
  if answer ~= nil then return answer end
  if why == "cancelled" or why == "timeout" then return nil end
  if why == "unsupported" or why == "no_client" then
    warn("Rex couldn't ask in the command palette (" .. tostring(why) .. "); using the float")
    return nil, true
  end
  if why == "busy" then fail("Rex is already asking something") end
  fail("Rex couldn't ask: " .. tostring(detail or why))
end

-- The project directories in picker order, as sessionizer.sh --list prints
-- them for the session labelled current.
local function project_dirs(current)
  local result, err = rex.exec({
    M.options.script,
    "--work-dir", M.options.work_dir,
    "--current",  current,
    "--list",
  }, { timeout = 10 })
  if result == nil then fail("can't run " .. M.options.script .. ": " .. tostring(err)) end
  if not result.ok then fail("listing projects failed: " .. first_line(result.stderr)) end
  local dirs = {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do dirs[#dirs + 1] = line end
  return dirs
end

-- A project directory as the palette shows it: relative to work_dir.
local function project_title(path)
  local prefix = M.options.work_dir .. "/"
  if path:sub(1, #prefix) == prefix then return path:sub(#prefix + 1) end
  return tilde(path)
end

-- The picker's items: each directory, marked when it has a session already.
local function project_items(dirs, current)
  local labelled = {}
  for _, s in ipairs(sessions()) do
    if s.label then labelled[s.label] = true end
  end
  local items = {}
  for _, path in ipairs(dirs) do
    if #items >= MAX_ITEMS then break end
    local name = basename(path)
    local detail
    if name == current then
      detail = "current"
    elseif labelled[name] then
      detail = "open"
    end
    items[#items + 1] = { id = path, title = project_title(path), icon = "folder", detail = detail }
  end
  return items
end

local function native_pick(ctx)
  if not is_dir(M.options.work_dir) then
    fail("work_dir is not a directory: " .. M.options.work_dir)
  end
  local current = session_label(ctx.session_id) or ""
  local items = project_items(project_dirs(current), current)

  local answer, fallback = ask{
    title       = "Project",
    placeholder = #items > 0 and "Pick a project"
                  or ("Nothing under " .. tilde(M.options.work_dir)),
    items       = items,
  }
  if fallback then return float_pick(ctx) end
  if answer == nil then return { cancelled = true } end
  return M.go(ctx, answer)
end

--------------------------------------------------------------------------------
-- Actions and setup
--------------------------------------------------------------------------------

-- Open the picker over the session the action runs in. Returns the float's
-- layer_id when one opened; with the native picker, M.go's result, or
-- cancelled = true.
function M.open(ctx)
  if use_native(ctx) then return native_pick(ctx) end
  return float_pick(ctx)
end

function M.setup(opts)
  local known = { layout = true, script = true }
  for k in pairs(M.options) do known[k] = true end
  for k, v in pairs(opts or {}) do
    if not known[k] then
      warn("ignoring unknown option " .. tostring(k))
    elseif k == "picker" and not PICKERS[v] then
      warn('ignoring option picker: expected "float" or "native", got ' .. tostring(v))
    else
      M.options[k] = v
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
