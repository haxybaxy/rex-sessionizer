-- Checks the picker option against the fake rex in fake_rex.lua: what the
-- native picker (picker = "native") lists in the palette, what it does with
-- each answer, and when it uses the fzf float instead. Needs only Lua 5.1 (or
-- LuaJIT):
--
--   luajit test/native_test.lua

local here = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local t = require("helper")
local fake = require("fake_rex").install()

local HOME = "/home/me"
local WORK = HOME .. "/work"
local SCRIPT = "/opt/sessionizer/sessionizer.sh"
local APP, API, API_FE = WORK .. "/app", WORK .. "/api", WORK .. "/api/api-fe"

-- What sessionizer.sh --list prints. A test changes a field to change it.
local listing

local function answer_command(argv)
  if argv[1] ~= SCRIPT then
    return { ok = false, code = 1, stdout = "", stderr = "unexpected command: " .. table.concat(argv, " ") }
  end
  if listing.fails then return { ok = false, code = 1, stdout = "", stderr = "find: boom\nmore" } end
  return { ok = true, code = 0, stdout = table.concat(listing.dirs, "\n") .. "\n", stderr = "" }
end

local function fresh(opts)
  fake:reset()
  fake.env.HOME = HOME
  fake.dirs = { [WORK] = true, [APP] = true, [API] = true, [API_FE] = true }
  fake.run = answer_command
  listing = { dirs = { API_FE, APP, API } }
  local options = { work_dir = "~/work", script = SCRIPT, picker = "native" }
  for k, v in pairs(opts or {}) do options[k] = v end
  return t.load_plugin(options)
end

-- A key press in a session labelled label.
local function key_ctx(label)
  return { origin = "key", session_id = fake:add_session(label or "home") }
end

local function questions() return fake:calls_to("ui.pick") end
local function question() local q = questions(); return q[#q] and q[#q].args end
local function floats() return fake:calls_to("session.new_layer") end

-- The script arguments of the last float.
local function float_args()
  local layers = floats()
  local layer = layers[#layers]
  if not layer then return nil end
  local command, args = layer.args.layout.block.options.command, {}
  for i = 2, #command do args[#args + 1] = command[i] end
  return args
end

-- A field of each item of the last question, as a list.
local function item_field(field)
  local values = {}
  for i, item in ipairs(question().items) do values[i] = item[field] or "-" end
  return values
end

--------------------------------------------------------------------------------
t.section("the option")
--------------------------------------------------------------------------------

do
  local M = fresh{ picker = "fzf" }
  t.check("an unknown picker is ignored with a warning",
    M.options.picker == "float" and #fake:warnings() == 1 and fake:warnings()[1]:find("picker", 1, true),
    t.show(fake:warnings()))
end

do
  local M = fresh{ picker = "float" }
  local result = M.open(key_ctx("app"))
  t.check("float opens the fzf float without asking or listing",
    #questions() == 0 and #fake:commands() == 0 and result.layer_id
      and t.same_list(float_args(), { "--work-dir", WORK, "--current", "app" }), t.show(float_args() or {}))
end

do
  fresh()
  local M = t.load_plugin{ work_dir = "~/work", script = SCRIPT }   -- no picker option
  M.open(key_ctx())
  t.check("the float is the default", M.options.picker == "float" and #questions() == 0 and #floats() == 1)
end

do
  local M = fresh()
  M.open(key_ctx())
  t.check("native asks in the palette instead of opening a float", #questions() == 1 and #floats() == 0)
end

--------------------------------------------------------------------------------
t.section("when Rex can't ask in the palette")
--------------------------------------------------------------------------------

do
  local M = fresh()
  rex.ui = nil
  M.open(key_ctx("app"))
  t.check("a Rex without rex.ui gets the fzf float, with a warning",
    t.same_list(float_args(), { "--work-dir", WORK, "--current", "app" }) and #fake:warnings() == 1,
    t.show(fake:warnings()))
end

do
  local M = fresh()
  local ctx = key_ctx()
  ctx.server = "devbox"
  M.open(ctx)
  t.check("a session on another host gets the float, without a warning or a listing here",
    #questions() == 0 and #floats() == 1 and #fake:commands() == 0 and #fake:warnings() == 0)
end

for _, why in ipairs{ "unsupported", "no_client" } do
  local M = fresh()
  fake:answer(nil, why)
  M.open(key_ctx())
  t.check(why .. " falls back to the fzf float",
    #floats() == 1 and #fake:warnings() == 1 and fake:warnings()[1]:find(why, 1, true), t.show(fake:warnings()))
end

do
  local M = fresh()
  fake:answer(nil, "busy")
  local err = t.error_of(M.open, key_ctx())
  t.check("busy is an error, with no float", err and err:find("already asking", 1, true) and #floats() == 0, err)
end

do
  local M = fresh()
  fake:answer(nil, "failed", "the prompt was too big")
  local err = t.error_of(M.open, key_ctx())
  t.check("failed is an error that says why", err and err:find("the prompt was too big", 1, true), err)
end

--------------------------------------------------------------------------------
t.section("what the picker lists")
--------------------------------------------------------------------------------

do
  local M = fresh()
  fake:add_session("api")
  M.open(key_ctx("app"))
  local prompt = question()
  local cmd = fake:commands()[1]
  t.check("lists with sessionizer.sh --list for the current session",
    cmd and t.same_list(cmd.argv, { SCRIPT, "--work-dir", WORK, "--current", "app", "--list" }),
    cmd and t.show(cmd.argv))
  t.check("in the script's order, by absolute path",
    t.same_list(item_field("id"), { API_FE, APP, API }), t.show(item_field("id")))
  t.check("titled relative to work_dir",
    t.same_list(item_field("title"), { "api/api-fe", "app", "api" }), t.show(item_field("title")))
  t.check("marks the current project and the ones with a session",
    t.same_list(item_field("detail"), { "-", "current", "open" }), t.show(item_field("detail")))
  t.check("each with a folder, and no typed answers",
    t.same_list(item_field("icon"), { "folder", "folder", "folder" })
      and not prompt.allow_other and prompt.title == "Project")
end

do
  local M = fresh()
  listing.dirs = {}
  M.open(key_ctx())
  t.check("with nothing to list, says so",
    #question().items == 0 and question().placeholder == "Nothing under ~/work", question().placeholder)
end

do
  local M = fresh()
  listing.fails = true
  local err = t.error_of(M.open, key_ctx())
  t.check("a failing listing is an error with its first line, asked nothing",
    err and err:find("listing projects failed: find: boom", 1, true) and not err:find("more", 1, true)
      and #questions() == 0, err)
end

do
  local M = fresh()
  fake.dirs[WORK] = nil
  local err = t.error_of(M.open, key_ctx())
  t.check("a missing work_dir is an error, before listing",
    err and err:find("work_dir is not a directory: " .. WORK, 1, true) and #fake:commands() == 0, err)
end

--------------------------------------------------------------------------------
t.section("what a pick does")
--------------------------------------------------------------------------------

do
  local M = fresh()
  fake:answer(API_FE)
  local result = M.open(key_ctx("app"))
  local created = fake:session(result.session_id)
  t.check("a project without a session gets one, labelled after its directory",
    result.created and result.path == API_FE and created and created.label == "api-fe")
  t.check("and the app shows it, with no float and no Remote Control",
    t.same_list(fake:selected(), { result.session_id }) and #fake:calls_to("client.queue") == 1
      and #fake:calls_to("client.perform") == 0 and #floats() == 0, t.show(fake:selected()))
end

do
  local M = fresh()
  local existing = fake:add_session("api")
  fake:answer(API)
  local result = M.open(key_ctx("app"))
  t.check("a project with a session switches to it",
    not result.created and result.session_id == existing and #fake:calls_to("session.create") == 0
      and t.same_list(fake:selected(), { existing }))
end

do
  local M = fresh()
  local result = M.open(key_ctx())
  t.check("cancelling does nothing",
    result.cancelled and #floats() == 0 and #fake:selected() == 0 and #fake:calls_to("session.create") == 0)
end

do
  local M = fresh()
  local ctx = { origin = "cli", session_id = fake:add_session("home") }
  local app = fake:add_app({ ctx.session_id })
  fake:answer(APP)
  local result = M.open(ctx)
  local perform = fake:calls_to("client.perform")[1]
  t.check("run from the CLI, the switch goes through client.perform",
    perform and perform.args.client_id == app.client_id and t.same_list(fake:selected(), { result.session_id }))
end

t.done()
