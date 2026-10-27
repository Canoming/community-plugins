-- Mocked service tests: no real processes, compositor or Herdr server are used.
local file = assert(io.open(arg[1] or "herdr/service.luau", "r"))
local source = file:read("a")
file:close()

local function fixture(options)
  options = options or {}
  local calls, opened, errors = {}, {}, {}
  local loaded = false
  local windows = options.windows or { { pid = 100, id = 42 } }
  local parents = options.parents or { [102] = 101, [101] = 100 }
  local context = {
    string = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end },
    state = { get = function() return false end, set = function() end, watch = function() end },
    commandExists = function(command) return command ~= "herdr" or loaded end,
    getenv = function(name) return name == "NIRI_SOCKET" and (options.hyprland and "" or "/mock/niri.sock") or "" end,
    readFile = function(path)
      local pid = tonumber(path:match("/proc/(%d+)/stat"))
      if parents[pid] then return pid .. " (mock) S " .. parents[pid] .. " 0 0" end
    end,
    json = { decode = function(value)
      if value == "windows" then return options.windows or windows end
      if value == "picked" then return options.picked end
    end },
    getConfig = function() return false end,
    setUpdateInterval = function() end,
    tr = function(key) return key end,
    log = function() end,
    notifyError = function(_, message) table.insert(errors, message) end,
    notify = function() end,
    runInTerminal = function(command) table.insert(opened, command); return true end,
  }
  context.runAsync = function(argv, callback)
    local command = table.concat(argv, " ")
    table.insert(calls, command)
    if options.spawnFail == command then return false end
    if command == "niri msg --json windows" then
      callback({ exitCode = options.listExit or 0, timedOut = options.listTimeout, stdout = "windows" })
    elseif command == "ps -C herdr -o pid=,args=" then
      callback({ exitCode = options.psExit or 0, stdout = options.processes or "102 /home/me/.local/bin/herdr\n" })
    elseif command == "niri msg --json pick-window" then
      if options.deferPick then
        options.resolvePick = callback
      else
        callback({ exitCode = options.pickExit or 0, timedOut = options.pickTimeout,
          stdout = options.pickRaw or (options.picked and "picked" or "null") })
      end
    elseif command:match("^niri msg action focus%-window") or command:match("^hyprctl dispatch ") then
      callback({ exitCode = options.focusExit or 0, stdout = "" })
    elseif command:match("^herdr .*agent focus ") or command:match("^herdr agent focus ") then
      if options.deferAgent then options.resolveAgent = callback
      else callback({ exitCode = options.agentExit or 0, stdout = "" }) end
    else
      callback({ exitCode = 1, stdout = "" }) -- No polling fixture needed for action tests.
    end
    return true
  end
  local env = setmetatable({ noctalia = context }, { __index = _G })
  local exported = assert(load(source .. [[
return { detect = detectSessionWindows, focus = focusWindowOrOpen,
  focusAgent = focusAgent, parse = sessionFromArgs, state = state }
]], "service.luau", "t", env))()
  loaded = true
  return exported, calls, opened, errors
end

local count = 0
local function test(name, fn)
  fn()
  count = count + 1
  print("ok " .. count .. " - " .. name)
end
local function includes(values, needle)
  for _, value in ipairs(values) do if value == needle then return true end end
  return false
end

test("default session maps through shell ancestry, with Niri preferred over installed hyprctl", function()
  local svc, calls = fixture()
  svc.detect(function(windows, err)
    assert(not err and windows.default.id == "42")
    assert(windows.default.compositor == "niri")
  end)
  assert(not includes(calls, "hyprctl clients -j"))
end)

test("named attachment syntax and non-client exclusions", function()
  local svc = fixture()
  assert(svc.parse("herdr --session project") == "project")
  assert(svc.parse("herdr --session=project") == "project")
  assert(svc.parse("herdr session attach project") == "project")
  assert(svc.parse("herdr --handoff --session project") == "project")
  for _, command in ipairs({ "herdr server", "herdr api snapshot", "herdr agent focus p:q", "herdr --remote host", "herdr --session project status" }) do
    assert(svc.parse(command) == nil, command)
  end
end)

test("agent click focuses pane then existing Niri window without opening a terminal", function()
  local svc, calls, opened = fixture()
  svc.focusAgent("default", "pane:1")
  assert(calls[1] == "herdr agent focus pane:1")
  assert(includes(calls, "niri msg action focus-window --id 42"))
  assert(#opened == 0)
end)

test("named session focuses its existing terminal", function()
  local svc, calls, opened = fixture({ processes = "102 herdr --session project" })
  svc.focusAgent("project", "pane:2")
  assert(calls[1] == "herdr --session project agent focus pane:2")
  assert(includes(calls, "niri msg action focus-window --id 42"))
  assert(#opened == 0)
end)

test("absent client opens requested named session", function()
  local svc, _, opened = fixture({ processes = "", psExit = 1 })
  svc.focus("project")
  assert(#opened == 1 and opened[1] == "herdr --session project")
end)

test("no windows opens default session", function()
  local svc, _, opened = fixture({ windows = {} })
  svc.focus("default")
  assert(#opened == 1 and opened[1] == "herdr")
end)

test("cancelled window selection stays quiet and permits a later retry", function()
  local svc, calls, opened, errors = fixture({ windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } } })
  svc.focus("default")
  assert(#opened == 0 and #errors == 0 and svc.state.action.status == "cancelled")
  assert(not includes(calls, "niri msg action focus-window --id 42"))
  svc.focus("default")
  local picks = 0
  for _, command in ipairs(calls) do if command == "niri msg --json pick-window" then picks = picks + 1 end end
  assert(picks == 2)
end)

test("shared PID prompts once and remembers the selected window", function()
  local svc, calls, opened, errors = fixture({ windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 43 } })
  svc.focus("default")
  svc.focus("default")
  local picks = 0
  for _, command in ipairs(calls) do if command == "niri msg --json pick-window" then picks = picks + 1 end end
  assert(picks == 1 and includes(calls, "niri msg action focus-window --id 43"))
  assert(#opened == 0 and #errors == 0)
end)

test("selecting an unrelated window never focuses it", function()
  local svc, calls, opened, errors = fixture({ windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 99 } })
  svc.focus("default")
  assert(not includes(calls, "niri msg action focus-window --id 99"))
  assert(#opened == 0 and #errors == 0 and svc.state.action.status == "cancelled")
end)

test("real picker failures still report an error", function()
  for _, extra in ipairs({ { pickExit = 1 }, { pickTimeout = true }, { pickRaw = "garbled" }, { spawnFail = "niri msg --json pick-window" } }) do
    extra.windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }
    local svc, _, opened, errors = fixture(extra)
    svc.focus("default")
    assert(#opened == 0 and errors[1] == "error.niri_picker_failed")
  end
end)

test("multiple attached clients retain a valid selection when process order changes", function()
  local options = { windows = { { pid = 100, id = 42 }, { pid = 200, id = 43 } }, picked = { id = 43 },
    processes = "102 herdr\n202 herdr\n", parents = { [102] = 100, [202] = 200 } }
  local svc, calls, opened, errors = fixture(options)
  svc.focus("default")
  options.processes = "202 herdr\n102 herdr\n"
  svc.focus("default")
  local picks, focuses = 0, 0
  for _, command in ipairs(calls) do
    if command == "niri msg --json pick-window" then picks = picks + 1 end
    if command == "niri msg action focus-window --id 43" then focuses = focuses + 1 end
  end
  assert(picks == 1 and focuses == 2 and #opened == 0 and #errors == 0)
end)

test("rapid clicks start only one picker and do not send another agent focus", function()
  local options = { windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 43 }, deferPick = true }
  local svc, calls, opened, errors = fixture(options)
  svc.focusAgent("default", "pane:1")
  svc.focusAgent("default", "pane:2")
  svc.focus("default")
  local picks = 0
  for _, command in ipairs(calls) do if command == "niri msg --json pick-window" then picks = picks + 1 end end
  assert(picks == 1 and not includes(calls, "herdr agent focus pane:2"))
  options.resolvePick({ exitCode = 0, stdout = "picked" })
  assert(includes(calls, "niri msg action focus-window --id 43"))
  assert(#opened == 0 and #errors == 0)
end)

test("focus is serialized even while the initial Herdr command is pending", function()
  local options = { deferAgent = true }
  local svc, calls, opened, errors = fixture(options)
  svc.focusAgent("default", "pane:1")
  svc.focusAgent("default", "pane:2")
  svc.focus("default")
  assert(#calls == 1)
  options.resolveAgent({ exitCode = 0, stdout = "" })
  assert(includes(calls, "niri msg action focus-window --id 42"))
  assert(#opened == 0 and #errors == 0)
end)

test("new candidates opened during selection are accepted after revalidation", function()
  local options = { windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 44 }, deferPick = true }
  local svc, calls, opened, errors = fixture(options)
  svc.focus("default")
  table.insert(options.windows, { pid = 100, id = 44 })
  options.resolvePick({ exitCode = 0, stdout = "picked" })
  assert(includes(calls, "niri msg action focus-window --id 44"))
  assert(#opened == 0 and #errors == 0)
end)

test("closed selected window is rejected on revalidation without a new terminal", function()
  local options = { windows = { { pid = 100, id = 42 }, { pid = 100, id = 43 } }, picked = { id = 43 }, deferPick = true }
  local svc, calls, opened, errors = fixture(options)
  svc.focus("default")
  options.windows = { { pid = 100, id = 42 } }
  options.resolvePick({ exitCode = 0, stdout = "picked" })
  assert(not includes(calls, "niri msg action focus-window --id 43"))
  assert(#opened == 0 and #errors == 0)
end)

test("panel closes before publishing a focus command, but not for refresh", function()
  local events, callbacks = {}, nil
  local env = setmetatable({
    require = function() return { build = function(_, options) callbacks = options; return {} end } end,
    noctalia = { state = { get = function() return {} end, watch = function() end,
      set = function(key) if key == "herdr.command" then table.insert(events, "command") end end } },
    panel = { render = function() end, close = function() table.insert(events, "close") end },
  }, { __index = _G })
  assert(loadfile("herdr/panel.luau", "t", env))()
  callbacks.request("focus_agent", "default", "pane:1")
  assert(events[1] == "close" and events[2] == "command")
  events = {}
  callbacks.request("refresh")
  assert(#events == 1 and events[1] == "command")
end)

test("failed or timed-out window listing does not create duplicate terminals", function()
  for _, options in ipairs({ { listExit = 1 }, { listTimeout = true }, { spawnFail = "niri msg --json windows" } }) do
    local svc, _, opened, errors = fixture(options)
    svc.focus("default")
    assert(#opened == 0 and #errors == 1)
  end
end)

test("process-list errors do not create duplicate terminals", function()
  local svc, _, opened, errors = fixture({ psExit = 2 })
  svc.focus("default")
  assert(#opened == 0 and #errors == 1)
end)

test("failed focus reports an error without creating duplicate terminals", function()
  for _, options in ipairs({ { focusExit = 1 }, { spawnFail = "niri msg action focus-window --id 42" } }) do
    local svc, _, opened, errors = fixture(options)
    svc.focus("default")
    assert(#opened == 0 and errors[1] == "error.niri_focus_failed")
  end
end)

test("window ID zero is accepted and invalid window records are ignored", function()
  local svc, calls = fixture({ windows = { { id = "bad", pid = 100 }, { id = 0, pid = 100 }, { id = 10 } } })
  svc.focus("default")
  assert(includes(calls, "niri msg action focus-window --id 0"))
end)

test("Hyprland focus behavior remains available outside Niri", function()
  local svc, calls, opened = fixture({ hyprland = true })
  svc.state.sessions = { { name = "default", window = { address = "0x123", workspace = "2" } } }
  svc.focus("default")
  assert(includes(calls, 'hyprctl dispatch hl.dsp.focus({ window = "address:0x123" })'))
  assert(#opened == 0)
end)

print(count .. " tests passed")
