-- A simulated Hammerspoon: just enough of the hs.* API, with a fake clock,
-- fake apps, a fake clipboard and a fake review panel.
local TESTDIR, REPO = ...
local json = dofile(TESTDIR .. "json.lua")

local M = {}

local function copyTable(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return c end

function M.reset()
  M.clock = 100
  M.timers = {}
  M.keys, M.pasted, M.alerts, M.requests, M.logs, M.webviews, M.executed = {}, {}, {}, {}, {}, {}, {}
  M.pb = { items = { ["public.utf8-plain-text"] = "OLD CLIPBOARD", ["public.rtf"] = "{\\rtf old}" }, count = 5 }
  M.modifiersHeld = false
  M.axTrusted = true
  M.axPrompted = false
  M.keychainKey = "sk-ant-test-key"
  M.httpDelay = 0.5
  M.httpResponder = nil
  M.apps = {}
  M.apps.editor = M.newApp("Editor", 100)
  M.apps.hammerspoon = M.newApp("Hammerspoon", 1)
  M.front = M.apps.editor
  M.panelWindow = { focus = function(self) M.front = M.apps.hammerspoon; return self end }
end

function M.newApp(name, pid)
  local app = { name_ = name, pid_ = pid, selection = nil }
  function app:pid() return self.pid_ end
  function app:name() return self.name_ end
  function app:activate() M.front = self; return true end
  app.window = {
    app = app,
    focus = function(self) M.front = self.app; return self end,
    screen = function() return M.screen end,
    application = function(self) return self.app end,
  }
  return app
end

M.screen = { frame = function() return { x = 0, y = 25, w = 1440, h = 875 } end }

local function newTimer(delay, fn, interval)
  local t = { at = M.clock + delay, fn = fn, interval = interval, active = true }
  function t:stop() self.active = false; return self end
  M.timers[#M.timers + 1] = t
  return t
end

function M.schedule(delay, fn) return newTimer(delay, fn) end

-- Advances the fake clock, firing timers in order, up to `seconds` from now.
function M.run(seconds)
  local limit = M.clock + (seconds or 10)
  for _ = 1, 100000 do
    local nextTimer
    for _, t in ipairs(M.timers) do
      if t.active and (not nextTimer or t.at < nextTimer.at) then nextTimer = t end
    end
    if not nextTimer or nextTimer.at > limit then break end
    M.clock = nextTimer.at
    if nextTimer.interval then nextTimer.at = nextTimer.at + nextTimer.interval else nextTimer.active = false end
    nextTimer.fn()
  end
  M.clock = limit
  local live = {}
  for _, t in ipairs(M.timers) do if t.active then live[#live + 1] = t end end
  M.timers = live
end

function M.onKey(mods, code, down)
  M.keys[#M.keys + 1] = { mods = table.concat(mods, "+"), code = code, down = down, at = M.clock, heldMods = M.modifiersHeld }
  if not down then return end
  local app = M.front
  if mods[1] == "cmd" and code == 8 then
    if app.selection and app.selection ~= "" then
      M.schedule(0.01, function() hs.pasteboard.setContents(app.selection) end)
    end
  elseif mods[1] == "cmd" and code == 9 then
    M.pasted[#M.pasted + 1] = { app = app:name(), text = hs.pasteboard.getContents() }
  end
end

-- The panel side: what the page would post back, and what it was sent.
function M.webview() return M.webviews[#M.webviews] end
function M.panelPost(body)
  local wv = M.webview()
  wv.uc.cb({ body = body, name = "proofread" })
end
-- The payload of the most recent window.proofread.<fn>(...) call (default: update).
function M.lastCall(fn)
  local wv = M.webview()
  for i = #wv.js, 1, -1 do
    local name, inner = wv.js[i]:match("^window%.proofread && window%.proofread%.([%w_]+)%((.*)%)$")
    if name == (fn or "update") then return json.decode(inner) end
  end
  return nil
end
function M.lastPayload() return M.lastCall("update") end
function M.json() return json end

hs = {
  json = { encode = function(v) return json.encode(v) end, decode = function(s) return json.decode(s) end },
  spoons = {
    scriptPath = function() return REPO .. "/" end,
    bindHotkeysToSpec = function(spec, mapping) M.boundSpec, M.boundMapping = spec, mapping end,
  },
  logger = { new = function()
    local l = {}
    for _, lvl in ipairs({ "e", "w", "i", "d", "f", "v" }) do
      l[lvl] = function(msg) M.logs[#M.logs + 1] = lvl .. ": " .. tostring(msg) end
    end
    return l
  end },
  timer = {
    doAfter = function(delay, fn) return newTimer(delay, fn) end,
    doEvery = function(interval, fn) return newTimer(interval, fn, interval) end,
    secondsSinceEpoch = function() return M.clock end,
    usleep = function() end,
  },
  pasteboard = {
    getContents = function() return M.pb.items["public.utf8-plain-text"] end,
    setContents = function(s) M.pb.items = { ["public.utf8-plain-text"] = s }; M.pb.count = M.pb.count + 1; return true end,
    clearContents = function() M.pb.items = {}; M.pb.count = M.pb.count + 1 end,
    changeCount = function() return M.pb.count end,
    readAllData = function() return copyTable(M.pb.items) end,
    writeAllData = function(t) M.pb.items = copyTable(t); M.pb.count = M.pb.count + 1; return true end,
  },
  eventtap = {
    checkKeyboardModifiers = function()
      if M.modifiersHeld then return { cmd = true, alt = true } end
      return {}
    end,
    event = {
      newKeyEvent = function(mods, code, down)
        assert(type(code) == "number", "newKeyEvent called with a non-numeric key")
        return { post = function() M.onKey(mods, code, down) end }
      end,
    },
  },
  keycodes = { map = { c = 8, v = 9, p = 35 } },
  application = { frontmostApplication = function() return M.front end },
  window = { focusedWindow = function() return M.front.window end },
  screen = { mainScreen = function() return M.screen end },
  canvas = { windowLevels = { floating = 3 } },
  drawing = { windowLevels = { floating = 3 } },
  alert = { show = function(msg) M.alerts[#M.alerts + 1] = msg end },
  accessibilityState = function(prompt)
    if prompt then M.axPrompted = true end
    return M.axTrusted
  end,
  focus = function() M.front = M.apps.hammerspoon end,
  execute = function(cmd)
    M.executed[#M.executed + 1] = cmd
    if cmd:find("find-generic-password", 1, true) and M.keychainKey then
      return M.keychainKey .. "\n", true, "exit", 0
    end
    if cmd:find("/usr/bin/git", 1, true) then -- real git, for prompt history
      local p = io.popen(cmd)
      local out = p:read("a")
      local ok = p:close()
      return out, ok, "exit", ok and 0 or 1
    end
    return "", nil, "exit", 44
  end,
  http = {
    asyncPost = function(url, body, headers, cb)
      local req = { url = url, body = body, headers = headers }
      M.requests[#M.requests + 1] = req
      M.schedule(M.httpDelay, function()
        local status, resp = M.httpResponder(req)
        cb(status, resp, {})
      end)
    end,
  },
  webview = {
    usercontent = { new = function(name)
      local uc = { name = name }
      function uc:setCallback(fn) self.cb = fn; return self end
      return uc
    end },
    new = function(rect, prefs, uc)
      local wv = { rect = rect, prefs = prefs, uc = uc, js = {}, shown = false, deleted = false, settings = {} }
      for _, n in ipairs({ "windowTitle", "windowStyle", "allowTextEntry", "allowNewWindows", "level", "shadow", "deleteOnClose", "bringToFront" }) do
        wv[n] = function(self, ...) self.settings[n] = { ... }; return self end
      end
      function wv:windowCallback(fn) self.wcb = fn; return self end
      function wv:html(h) self.htmlContent = h; return self end
      function wv:show() assert(not self.deleted, "show() on deleted webview"); self.shown = true; return self end
      function wv:hide() self.shown = false; return self end
      function wv:delete()
        assert(not self.deleted, "double delete")
        -- Real Hammerspoon fires the "closing" window callback on delete() too.
        if self.wcb then self.wcb("closing", self) end
        self.deleted = true
      end
      function wv:hswindow() return M.panelWindow end
      function wv:evaluateJavaScript(js)
        assert(not self.deleted, "evaluateJavaScript on deleted webview")
        self.js[#self.js + 1] = js
        return self
      end
      M.webviews[#M.webviews + 1] = wv
      return wv
    end,
  },
}

M.reset()
return M
