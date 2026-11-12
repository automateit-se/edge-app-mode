-- Mode (Läge): one shared mode for the installation, for example Hemma / Borta / Semester at home, or
-- Patient / Städ / Konferens / Larmat in a training flat. Other Edge Apps read it and act on it.
--
-- The app keeps one function of type "mode":
--   topic_read  obj/mode/<mode_name>       value = the state's number, msg = who or what changed it
--   topic_write set/obj/mode/<mode_name>   send a number or a key ("away") to change it
--   mode.states = 0:home:Hemma,1:away:Borta,2:vacation:Semester   (value:key:label)
--   mode.name   = <mode_name>
-- Apps refer to states by key, so states can be added or reordered without breaking them. The value is published
-- retained on the local broker, so an app that starts without internet still knows the mode.

local VERSION = "0.1.0"
local FUNCTION_TYPE = "mode"
local KEY_APP = "mode.app_id"

local M = {}

local function is_null(v) return v == nil or (json ~= nil and v == json.null) end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function str(v) if is_null(v) then return "" end return trim(v) end

-- ---- states ----------------------------------------------------------------------------------------------------

--- States from the configuration: { {value, key, label} } sorted by value, plus problems ({index, what}).
--- A state needs a whole number value >= 0 and a key of lower case letters, digits, _ and -; both unique.
function M.states(c)
  local out, problems, seen_v, seen_k = {}, {}, {}, {}
  for i, s in ipairs(type(c and c.states) == "table" and c.states or {}) do
    if type(s) == "table" then
      local v = tonumber(s.state_value)
      local key = str(s.state_key):lower()
      local label = str(s.state_label)
      if v == nil or v < 0 or v ~= math.floor(v) then
        problems[#problems + 1] = { i, "value" }
      elseif not key:match("^[a-z0-9_-]+$") then
        problems[#problems + 1] = { i, "key" }
      elseif seen_v[v] or seen_k[key] then
        problems[#problems + 1] = { i, "duplicate" }
      else
        seen_v[v], seen_k[key] = true, true
        out[#out + 1] = { value = math.floor(v), key = key, label = label ~= "" and label or key }
      end
    end
  end
  table.sort(out, function(a, b) return a.value < b.value end)
  return out, problems
end

--- "0:home:Hemma,1:away:Borta" (labels with , or : are cleaned so the text can be split again).
function M.encode(states)
  local parts = {}
  for _, s in ipairs(states) do
    parts[#parts + 1] = string.format("%d:%s:%s", s.value, s.key, (s.label:gsub("[,:]", " ")))
  end
  return table.concat(parts, ",")
end

--- The reverse of encode, for other apps: { {value, key, label} }.
function M.decode(text)
  local out = {}
  for part in tostring(text or ""):gmatch("[^,]+") do
    local v, key, label = part:match("^%s*(%d+):([%w_%-]+):?(.*)$")
    if v then out[#out + 1] = { value = tonumber(v), key = key, label = trim(label) ~= "" and trim(label) or key } end
  end
  return out
end

--- The state a requested value means: a number, a key or a label (case does not matter). nil when unknown.
function M.find(states, wanted)
  if is_null(wanted) then return nil end
  local n = tonumber(wanted)
  local w = trim(wanted):lower()
  for _, s in ipairs(states) do
    if (n ~= nil and s.value == n) or s.key == w or s.label:lower() == w then return s end
  end
  return nil
end

--- The function the app should have.
function M.wanted_function(current, states, c, app_id)
  local mode_name = str(c.mode_name):lower()
  if mode_name == "" then mode_name = "default" end
  local meta = {}
  for k, v in pairs(current and current.meta or {}) do meta[k] = v end
  meta.name = (current and current.meta and current.meta.name and current.meta.name ~= "") and current.meta.name
    or (str(c.name) ~= "" and str(c.name) or "Läge")
  meta.topic_read = "obj/mode/" .. mode_name
  meta.topic_write = "set/obj/mode/" .. mode_name
  meta["mode.name"] = mode_name
  meta["mode.states"] = M.encode(states)
  meta[KEY_APP] = tostring(app_id)
  return { type = FUNCTION_TYPE, meta = meta }
end

-- ---- edge client glue ----------------------------------------------------------------------------------------------

local state = { states = {}, current = nil, fn = nil, topic = nil, ready = false }

local function publish(s, msg)
  state.current = s
  mq:pub(state.topic, json:encode({ value = s.value, msg = msg or "", timestamp = os.time() }), true, 1)
end

local function same_meta(a, b)
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function own_function()
  for _, fn in ipairs(lynx.getFunctions({ [KEY_APP] = tostring(app.id) }) or {}) do
    if fn.meta and fn.meta[KEY_APP] == tostring(app.id) then return fn end
  end
  return nil
end

function M.sync()
  local current = own_function()
  local wanted = M.wanted_function(current, state.states, cfg, app.id)
  if current == nil then
    wanted.installation_id = app.installation_id
    lynx.createFunction(wanted)
    log.i("mode %s: function created (%s)", VERSION, wanted.meta.topic_read)
  elseif current.type ~= FUNCTION_TYPE or not same_meta(wanted.meta, current.meta or {}) then
    lynx.apiCall("PUT", "/api/v2/functionx/" .. tostring(current.installation_id or app.installation_id) .. "/" .. tostring(current.id), {
      id = current.id,
      installation_id = current.installation_id or app.installation_id,
      type = FUNCTION_TYPE,
      meta = wanted.meta,
      protected_meta = current.protected_meta or {},
    })
    log.i("mode %s: function %s updated", VERSION, tostring(current.id))
  end
  return wanted.meta.topic_read
end

--- A request on set/obj/mode/<name>: a number, key or label. Unknown values are refused and the current state is
--- published again, so a dashboard that showed the wrong value goes back.
function M.on_set(_, payload)
  local ok, data = pcall(json.decode, json, payload)
  local wanted = ok and type(data) == "table" and data.value or trim(payload)
  local s = M.find(state.states, wanted)
  if s == nil then
    log.w("unknown mode %s refused", tostring(wanted))
    if state.current then publish(state.current, "refused: " .. tostring(wanted)) end
    return
  end
  local who = ok and type(data) == "table" and not is_null(data.msg) and trim(data.msg) or ""
  if state.current and state.current.value == s.value then
    publish(s, who ~= "" and who or "unchanged")
    return
  end
  log.i("mode: %s -> %s%s", state.current and state.current.key or "-", s.key, who ~= "" and (" (" .. who .. ")") or "")
  publish(s, who)
end

--- The retained value from the local broker (or IoT Open) at start: a known state keeps it, otherwise the
--- configured initial state.
function M.on_current(_, payload)
  if state.ready then return end
  state.ready = true
  local ok, data = pcall(json.decode, json, payload)
  local s = ok and type(data) == "table" and M.find(state.states, data.value) or nil
  if s then
    state.current = s
    log.i("mode: %s (kept)", s.key)
  else
    M.start_initial()
  end
end

--- No retained value on the local broker (for example a new broker): the last value IoT Open has, if it can be
--- reached, otherwise the configured initial state.
function M.start_initial()
  state.ready = true
  local ok, statuses = pcall(lynx.getStatus, { state.topic })
  if ok and type(statuses) == "table" then
    for _, st in ipairs(statuses) do
      local s = type(st) == "table" and M.find(state.states, st.value)
      if s then
        publish(s, "restored")
        log.i("mode: %s (restored from IoT Open)", s.key)
        return
      end
    end
  end
  local s = M.find(state.states, str(cfg.initial_state)) or state.states[1]
  if s then publish(s, "start") log.i("mode: %s (initial)", s.key) end
end

function onStart()
  local problems
  state.states, problems = M.states(cfg)
  for _, p in ipairs(problems) do log.w("state %d: %s is missing or not valid", p[1], p[2]) end
  if #state.states == 0 then
    log.e("no valid states: nothing to do")
    return
  end
  local ok, topic = pcall(M.sync)
  if not ok then
    log.e("could not create or update the mode function: %s", tostring(topic))
    local name = str(cfg.mode_name):lower()
    topic = "obj/mode/" .. (name ~= "" and name or "default")
  end
  state.topic = topic
  mq:sub("set/" .. topic, 1)
  mq:bind("set/" .. topic, M.on_set)
  -- the retained value arrives right after subscribing; without one, the initial state is used
  mq:sub(topic, 1)
  mq:bind(topic, M.on_current)
  timer:after(3, function() if not state.ready then M.start_initial() end end)
  log.i("mode %s: %d states on %s", VERSION, #state.states, topic)
end

function onFunctionsUpdated()
  if #state.states > 0 then
    local ok, err = pcall(M.sync)
    if not ok then log.e("could not update the mode function: %s", tostring(err)) end
  end
end

function onExit() end

function onDestroy()
  pcall(function()
    local fn = own_function()
    if fn then lynx.deleteFunction(fn.id) end
  end)
end

-- iotopen-rt treats anything the app's code returns as an error, so the functions are only handed out to the tests
if MODE_TEST then
  M._state = state
  return M
end
