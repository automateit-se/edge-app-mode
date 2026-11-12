-- Tests for app.lua without an edge client: run with `lua5.3 tests/test_app.lua` from the repository root.
-- The edge client (cfg, app, log, json, lynx, mq, timer) is simulated. All names are made up.

local failures, count = 0, 0
local function check(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then print("ok   " .. name) else failures = failures + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, what)
  if a ~= b then error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2) end
end

local json = { null = setmetatable({}, {}) }
function json:encode(v)
  local parts = {}
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local x = v[k]
    parts[#parts + 1] = '"' .. k .. '":' .. (type(x) == "string" and ('"' .. x .. '"') or tostring(x))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
function json:decode(s)
  if not s:match("^%s*{") then error("not json") end
  local out = {}
  for k, v in s:gmatch('"([%w_]+)"%s*:%s*("?[^,"}]*"?)') do
    if v:sub(1, 1) == '"' then out[k] = v:sub(2, -2) else out[k] = tonumber(v) end
  end
  return out
end

local HOME = {
  name = "Läge", mode_name = "default", initial_state = "home",
  states = {
    { state_value = 1, state_key = "away", state_label = "Borta" },
    { state_value = 0, state_key = "home", state_label = "Hemma" },
    { state_value = 2, state_key = "vacation", state_label = "Semester" },
  },
}

local function load_app(opts)
  local sim = { clock = 1794300000, timers = {}, published = {}, handlers = {}, logs = {}, functions = opts.functions or {}, calls = {} }
  local lynx = {
    getFunctions = function(filter)
      local out = {}
      for _, f in ipairs(sim.functions) do
        local hit = true
        for k, v in pairs(filter or {}) do if (f.meta or {})[k] ~= v then hit = false end end
        if hit then out[#out + 1] = f end
      end
      return out
    end,
    createFunction = function(f)
      sim.calls[#sim.calls + 1] = { "create", f }
      f.id = 500 + #sim.functions
      sim.functions[#sim.functions + 1] = f
    end,
    apiCall = function(method, path, body)
      sim.calls[#sim.calls + 1] = { method, path, body }
      for i, f in ipairs(sim.functions) do if f.id == body.id then sim.functions[i] = body end end
      return body
    end,
    deleteFunction = function(id)
      for i, f in ipairs(sim.functions) do if f.id == id then table.remove(sim.functions, i) break end end
    end,
    getStatus = function() return opts.status or {} end,
  }
  local mq = {}
  function mq:sub() end
  function mq:bind(topic, fn) sim.handlers[topic] = fn end
  function mq:pub(topic, payload, retain) sim.published[#sim.published + 1] = { topic = topic, data = json:decode(payload), retain = retain } end
  local timer = {}
  function timer:after(secs, fn) sim.timers[#sim.timers + 1] = { at = sim.clock + secs, fn = fn } end
  local function logger(l) return function(f, ...) sim.logs[#sim.logs + 1] = l .. " " .. string.format(f, ...) end end
  local env = setmetatable({
    MODE_TEST = true, cfg = opts.cfg or HOME, app = { id = 3, installation_id = 1001 },
    json = json, lynx = lynx, mq = mq, timer = timer,
    os = setmetatable({ time = function() return sim.clock end }, { __index = os }),
    log = { i = logger("I"), e = logger("E") },
  }, { __index = _G })
  local M = assert(loadfile("app.lua", "t", env))()
  function sim.advance(secs)
    sim.clock = sim.clock + secs
    local due = {}
    for i = #sim.timers, 1, -1 do if sim.timers[i].at <= sim.clock then due[#due + 1] = table.remove(sim.timers, i) end end
    for _, t in ipairs(due) do t.fn() end
  end
  function sim.last() return sim.published[#sim.published] end
  function sim.send(topic, payload) sim.handlers[topic](topic, payload) end
  return M, env, sim
end

check("states are checked, sorted and encoded", function()
  local M = load_app({})
  local states, problems = M.states({ states = {
    { state_value = 1, state_key = "Away", state_label = "Borta" },
    { state_value = 0, state_key = "home", state_label = "Hemma, inne" },
    { state_value = 1, state_key = "x" },
    { state_value = 2, state_key = "bad key" },
    { state_value = -1, state_key = "neg" },
    { state_value = 3, state_key = "armed" },
  } })
  eq(#states, 3, "valid states")
  eq(#problems, 3, "problems")
  eq(M.encode(states), "0:home:Hemma  inne,1:away:Borta,3:armed:armed", "encoded")
  local back = M.decode(M.encode(states))
  eq(back[2].key, "away", "decoded key")
  eq(back[3].label, "armed", "label defaults to the key")
end)

check("a state is found by number, key or label", function()
  local M = load_app({})
  local states = M.states(HOME)
  eq(M.find(states, 2).key, "vacation", "number")
  eq(M.find(states, "2").key, "vacation", "number as text")
  eq(M.find(states, "Away").key, "away", "key")
  eq(M.find(states, "semester").key, "vacation", "label")
  eq(M.find(states, "nope"), nil, "unknown")
end)

check("first start creates the function and publishes the initial state retained", function()
  local _, env, sim = load_app({})
  env.onStart()
  eq(#sim.functions, 1, "function")
  local f = sim.functions[1]
  eq(f.type, "mode", "type")
  eq(f.meta.topic_read, "obj/mode/default", "topic_read")
  eq(f.meta.topic_write, "set/obj/mode/default", "topic_write")
  eq(f.meta["mode.states"], "0:home:Hemma,1:away:Borta,2:vacation:Semester", "states")
  sim.advance(3)
  eq(sim.last().topic, "obj/mode/default", "published")
  eq(sim.last().data.value, 0, "initial home")
  eq(sim.last().retain, true, "retained")
end)

check("a retained value on the local broker is kept after a restart", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.send("obj/mode/default", '{"value":2,"msg":"x"}')
  sim.advance(3)
  eq(#sim.published, 0, "nothing published: the state is kept")
end)

check("without a retained value the last value in IoT Open is restored", function()
  local _, env, sim = load_app({ status = { { topic = "4711/obj/mode/default", value = 1 } } })
  env.onStart()
  sim.advance(3)
  eq(sim.last().data.value, 1, "away restored")
  eq(sim.last().data.msg, "restored", "msg")
end)

check("changes by number, key or label, with who changed it", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.advance(3)
  sim.send("set/obj/mode/default", '{"value":"away","msg":"Personal via knapp"}')
  eq(sim.last().data.value, 1, "away")
  eq(sim.last().data.msg, "Personal via knapp", "who")
  sim.send("set/obj/mode/default", '{"value":2}')
  eq(sim.last().data.value, 2, "vacation by number")
  sim.send("set/obj/mode/default", "home")
  eq(sim.last().data.value, 0, "plain text key")
end)

check("an unknown value is refused and the current state published again", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.advance(3)
  sim.send("set/obj/mode/default", '{"value":7}')
  eq(sim.last().data.value, 0, "still home")
  assert(sim.last().data.msg:find("refused", 1, true), sim.last().data.msg)
end)

check("changed states update the function; a name changed by hand is kept", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.functions[1].meta.name = "Läge lägenhet 3"
  env.cfg = { name = "Läge", mode_name = "default", states = {
    { state_value = 0, state_key = "patient", state_label = "Patient" },
    { state_value = 1, state_key = "cleaning", state_label = "Städ" },
    { state_value = 3, state_key = "armed", state_label = "Larmat" },
  } }
  env.onStart()
  local f = sim.functions[1]
  eq(f.meta["mode.states"], "0:patient:Patient,1:cleaning:Städ,3:armed:Larmat", "states")
  eq(f.meta.name, "Läge lägenhet 3", "name kept")
  eq(sim.calls[#sim.calls][1], "PUT", "updated")
end)

check("no valid states: nothing is created", function()
  local _, env, sim = load_app({ cfg = { states = { { state_value = "x", state_key = "home" } } } })
  env.onStart()
  eq(#sim.functions, 0, "no function")
end)

check("the code returns nothing in the edge client", function()
  local env = setmetatable({ cfg = {}, app = { id = 1 }, log = { i = print, e = print }, json = { null = {} } }, { __index = _G })
  local chunk = assert(loadfile("app.lua", "t", env))
  eq(select("#", chunk()), 0, "returned values")
end)

print(string.format("%d of %d passed", count - failures, count))
os.exit(failures == 0 and 0 or 1)
