--- === Proofread ===
---
--- Select text in any app, press a hotkey, and review Claude's proofreading
--- suggestions one by one. The changes you accept are pasted back over your
--- selection; Cancel leaves everything as it was.
---
--- Home: https://github.com/adagioburner/proofread

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "Proofread"
obj.version = "0.1.0"
obj.author = "Andrei Burago"
obj.homepage = "https://github.com/adagioburner/proofread"

---------------------------------------------------------------------------
-- Settings. Override any of these in ~/.hammerspoon/init.lua after
-- hs.loadSpoon("Proofread"), e.g. spoon.Proofread.model = "claude-haiku-5-5"
---------------------------------------------------------------------------

--- Proofread.model
--- Variable
--- Claude model to use.
obj.model = "claude-sonnet-5-5"

--- Proofread.effort
--- Variable
--- How much work Claude puts into each request: "low" (fastest and cheapest),
--- "medium" or "high". Set to nil to use the model's default.
obj.effort = "low"

--- Proofread.maxTokens
--- Variable
--- Upper limit on the length of Claude's reply, in tokens.
obj.maxTokens = 16000

--- Proofread.keychainService
--- Variable
--- Name of the Keychain item that holds your Anthropic API key.
obj.keychainService = "proofread-anthropic-api-key"

--- Proofread.promptFile
--- Variable
--- Path to the instructions sent to Claude. nil means prompt.md in this Spoon.
obj.promptFile = nil

--- Proofread.acceptByDefault
--- Variable
--- Whether suggestions start out accepted (true) or rejected (false).
obj.acceptByDefault = true

--- Proofread.panelSize
--- Variable
--- Size of the review panel.
obj.panelSize = { w = 760, h = 560 }

--- Proofread.clipboardRestoreDelay
--- Variable
--- Seconds to wait after pasting before your previous clipboard is restored.
obj.clipboardRestoreDelay = 0.6

--- Proofread.debug
--- Variable
--- Enables "Inspect Element" in the panel and more logging.
obj.debug = false

---------------------------------------------------------------------------

local API_URL = "https://api.anthropic.com/v1/messages"
local API_VERSION = "2023-06-01"

-- The JSON shape Claude must answer in. Kept as a raw string so the property
-- order (changes first, then the full text) is preserved exactly.
local RESULT_SCHEMA = [[
{
  "type": "object",
  "properties": {
    "changes": {
      "type": "array",
      "description": "One entry per change, in the order they occur in the text.",
      "items": {
        "type": "object",
        "properties": {
          "original": { "type": "string", "description": "The exact text that was replaced, copied verbatim from the input." },
          "replacement": { "type": "string", "description": "The exact text that replaces it." },
          "reason": { "type": "string", "description": "Why the change was made, in one short sentence." }
        },
        "required": ["original", "replacement", "reason"],
        "additionalProperties": false
      }
    },
    "corrected_text": {
      "type": "string",
      "description": "The complete text with all of the changes applied and nothing else altered."
    }
  },
  "required": ["changes", "corrected_text"],
  "additionalProperties": false
}
]]
local FORMAT_JSON = '{"type":"json_schema","schema":' .. RESULT_SCHEMA .. "}"
local FORMAT_PLACEHOLDER = '"__PROOFREAD_FORMAT__"'

-- Virtual key codes for C and V on the US layout. Used when the current
-- layout has no Latin letters (Russian, Greek, ...): macOS still treats
-- Cmd plus that physical key as Copy/Paste.
local KEYCODE_C, KEYCODE_V = 8, 9

local spoonPath = hs.spoons.scriptPath()
local log = hs.logger.new("Proofread", "info")

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function trim(s)
  s = s:gsub("^%s+", "")
  s = s:gsub("%s+$", "")
  return s
end

local function expandHome(path)
  if path:sub(1, 2) == "~/" then return os.getenv("HOME") .. path:sub(2) end
  return path
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("a")
  f:close()
  return content
end

local function writeFile(path, content)
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  local ok, writeErr = f:write(content)
  f:close()
  if not ok then return nil, writeErr end
  return true
end

-- /Users/me/x -> ~/x, for showing paths in the panel.
local function displayPath(path)
  local home = os.getenv("HOME")
  if home and path:sub(1, #home + 1) == home .. "/" then return "~" .. path:sub(#home + 1) end
  return path
end

local function shellQuote(s)
  local escaped = s:gsub("'", "'\\''")
  return "'" .. escaped .. "'"
end

-- Timers are kept in this table until they finish so they are never
-- garbage-collected while still pending.
local liveTimers = {}

local function after(delay, fn)
  local t
  t = hs.timer.doAfter(delay, function()
    liveTimers[t] = nil
    fn()
  end)
  liveTimers[t] = true
  return t
end

-- Calls check() every `interval` seconds until it returns true or `timeout`
-- seconds pass, then calls done(succeeded).
local function poll(interval, timeout, check, done)
  local started = hs.timer.secondsSinceEpoch()
  local t
  t = hs.timer.doEvery(interval, function()
    local ok, result = pcall(check)
    local succeeded = ok and result and true or false
    if succeeded or hs.timer.secondsSinceEpoch() - started >= timeout then
      t:stop()
      liveTimers[t] = nil
      done(succeeded)
    end
  end)
  liveTimers[t] = true
  return t
end

---------------------------------------------------------------------------
-- Keyboard and clipboard
---------------------------------------------------------------------------

local function pressWithCmd(letter, fallbackCode)
  local code = hs.keycodes.map[letter]
  if type(code) ~= "number" then code = fallbackCode end
  hs.eventtap.event.newKeyEvent({ "cmd" }, code, true):post()
  hs.timer.usleep(20000)
  hs.eventtap.event.newKeyEvent({ "cmd" }, code, false):post()
end

-- Waits until the hotkey's modifier keys are released, so they don't mix
-- with the Cmd-C we send.
local function afterModifiersReleased(fn)
  poll(0.02, 1.0, function()
    local m = hs.eventtap.checkKeyboardModifiers()
    return not (m.cmd or m.alt or m.shift or m.ctrl)
  end, function() fn() end)
end

local function snapshotClipboard()
  local snapshot = { text = hs.pasteboard.getContents() }
  local ok, data = pcall(hs.pasteboard.readAllData)
  if ok and type(data) == "table" then snapshot.data = data end
  return snapshot
end

local function restoreClipboard(snapshot)
  if not snapshot then return end
  if snapshot.data then
    if next(snapshot.data) == nil then
      hs.pasteboard.clearContents()
      return
    end
    local ok, written = pcall(hs.pasteboard.writeAllData, snapshot.data)
    if ok and written then return end
  end
  if snapshot.text then
    hs.pasteboard.setContents(snapshot.text)
  else
    hs.pasteboard.clearContents()
  end
end

-- Puts the user's clipboard back, but only if nothing has changed it since
-- we last wrote to it: if they copied something themselves while the panel
-- was open, that wins.
local function restoreIfUntouched(session)
  if hs.pasteboard.changeCount() == session.expectedChangeCount then
    restoreClipboard(session.clipboard)
  end
end

-- Sends Cmd-C to the frontmost app and calls done(text, copied). text is nil
-- and copied is false if the clipboard didn't change (usually: nothing was
-- selected).
local function copySelection(done)
  local before = hs.pasteboard.changeCount()
  pressWithCmd("c", KEYCODE_C)
  poll(0.03, 1.0, function()
    return hs.pasteboard.changeCount() ~= before
  end, function(changed)
    if not changed then return done(nil, false) end
    -- Give the app a moment to finish writing to the clipboard.
    after(0.05, function() done(hs.pasteboard.getContents(), true) end)
  end)
end

local function isFrontmost(app)
  local front = hs.application.frontmostApplication()
  return front ~= nil and app ~= nil and front:pid() == app:pid()
end

-- Brings the app (and window) the text came from back to the front.
local function refocus(session, thenDo)
  local focused = false
  if session.win then
    focused = pcall(function() session.win:focus() end)
  end
  if not focused and session.app then
    pcall(function() session.app:activate() end)
  end
  if not session.app then
    if thenDo then thenDo(false) end
    return
  end
  poll(0.03, 1.5, function() return isFrontmost(session.app) end, function(ok)
    if thenDo then thenDo(ok) end
  end)
end

local function pasteInto(session, text, restoreDelay)
  hs.pasteboard.setContents(text)
  session.expectedChangeCount = hs.pasteboard.changeCount()
  refocus(session, function(ok)
    if not ok then
      hs.alert.show("Proofread: couldn't switch back to the original app.\nThe corrected text is on your clipboard.", 4)
      return
    end
    after(0.15, function()
      pressWithCmd("v", KEYCODE_V)
      after(restoreDelay, function() restoreIfUntouched(session) end)
    end)
  end)
end

---------------------------------------------------------------------------
-- Claude API
---------------------------------------------------------------------------

function obj:_apiKey()
  local command = "/usr/bin/security find-generic-password -s " .. shellQuote(self.keychainService) .. " -w 2>/dev/null"
  local output, ok = hs.execute(command)
  local key = output and trim(output) or ""
  if ok and key ~= "" then return key end
  return nil
end

---------------------------------------------------------------------------
-- The prompt file
---------------------------------------------------------------------------

function obj:_promptPath()
  return expandHome(self.promptFile or (spoonPath .. "prompt.md"))
end

-- The text Claude gets: the prompt file without its <!-- comments -->.
function obj:_systemPrompt()
  local path = self:_promptPath()
  local content = readFile(path)
  if not content then return nil, "Couldn't read the prompt file:\n" .. displayPath(path) end
  content = trim(content:gsub("<!%-%-.-%-%->", ""))
  if content == "" then return nil, "The prompt file is empty:\n" .. displayPath(path) end
  return content
end

-- prompt.md as of the last git commit, or nil if that isn't available (a
-- custom promptFile, or the Spoon isn't a git checkout).
function obj:_committedPrompt()
  if self.promptFile then return nil end
  local output, ok = hs.execute("/usr/bin/git -C " .. shellQuote(spoonPath) .. " show HEAD:prompt.md 2>/dev/null")
  if ok and type(output) == "string" then return output end
  return nil
end

function obj:_sendPrompt(session)
  local path = self:_promptPath()
  local text = readFile(path)
  self:_call(session, "showPrompt", {
    text = text or "",
    path = displayPath(path),
    committed = self:_committedPrompt(),
    error = (not text) and ("Couldn't read " .. displayPath(path)) or nil,
  })
end

function obj:_savePrompt(session, text, recheck)
  if type(text) ~= "string" then return end
  if text:sub(-1) ~= "\n" then text = text .. "\n" end
  local path = self:_promptPath()
  local ok, err = writeFile(path, text)
  if not ok then
    return self:_call(session, "promptSaved", {
      ok = false,
      error = "Couldn't save " .. displayPath(path) .. ": " .. tostring(err),
    })
  end
  self:_call(session, "promptSaved", {
    ok = true,
    text = text,
    committed = self:_committedPrompt(),
    recheck = recheck and true or false,
  })
  if recheck then
    self:_send(session, { state = "loading", original = session.original })
    self:_requestCorrections(session)
  end
end

function obj:_requestBody(system, text)
  local outputConfig = { format = "__PROOFREAD_FORMAT__" }
  if self.effort then outputConfig.effort = self.effort end
  local body = hs.json.encode({
    model = self.model,
    max_tokens = self.maxTokens,
    system = system,
    messages = {
      {
        role = "user",
        content = "Proofread the text between the <text> tags.\n\n<text>\n" .. text .. "\n</text>",
      },
    },
    output_config = outputConfig,
  })
  -- Splice the schema in verbatim (see RESULT_SCHEMA above).
  local s, e = body:find(FORMAT_PLACEHOLDER, 1, true)
  return body:sub(1, s - 1) .. FORMAT_JSON .. body:sub(e + 1)
end

-- Turns the API's HTTP response into { changes = ..., corrected_text = ... }
-- or nil plus an error message.
local function parseResponse(status, body)
  if type(status) ~= "number" or status <= 0 then
    local detail = (type(body) == "string" and body ~= "") and ("\n" .. body) or ""
    return nil, "Couldn't reach the Claude API. Check your internet connection." .. detail
  end
  local ok, data = pcall(hs.json.decode, body or "")
  if not ok or type(data) ~= "table" then
    return nil, ("The Claude API sent an unexpected response (HTTP %d)."):format(status)
  end
  if status ~= 200 then
    if status == 401 then
      return nil, "The Claude API rejected your API key. Check the key stored in your Keychain."
    end
    local message = type(data.error) == "table" and data.error.message or nil
    return nil, ("Claude API error (HTTP %d): %s"):format(status, message or "unknown error")
  end
  if data.stop_reason == "max_tokens" then
    return nil, "The text is too long for one request. Select less text, or raise spoon.Proofread.maxTokens."
  end
  if data.stop_reason == "refusal" then
    return nil, "Claude declined to process this text."
  end
  local text
  for _, block in ipairs(data.content or {}) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      text = (text or "") .. block.text
    end
  end
  if not text then return nil, "Claude's reply contained no result." end
  local decoded, result = pcall(hs.json.decode, text)
  if not decoded or type(result) ~= "table" or type(result.corrected_text) ~= "string" then
    return nil, "Couldn't read Claude's reply."
  end
  if type(result.changes) ~= "table" then result.changes = {} end
  return result
end

function obj:_requestCorrections(session)
  local key = self:_apiKey()
  if not key then
    return self:_send(session, {
      state = "error",
      original = session.original,
      message = "No Anthropic API key found in your Keychain. Store it by running this in Terminal and pasting the key when asked:",
      code = "security add-generic-password -a \"$USER\" -s " .. self.keychainService .. " -w",
    })
  end
  local system, promptError = self:_systemPrompt()
  if not system then
    return self:_send(session, { state = "error", original = session.original, message = promptError })
  end

  session.requestId = (session.requestId or 0) + 1
  local requestId = session.requestId
  local body = self:_requestBody(system, session.core)
  local headers = {
    ["x-api-key"] = key,
    ["anthropic-version"] = API_VERSION,
    ["content-type"] = "application/json",
  }
  if self.debug then log.i("Requesting corrections from " .. self.model) end

  hs.http.asyncPost(API_URL, body, headers, function(status, responseBody)
    if session.closed or session.requestId ~= requestId then return end
    local result, err = parseResponse(status, responseBody)
    if not result then
      log.w(err)
      if self.debug and responseBody then log.i(responseBody) end
      return self:_send(session, { state = "error", original = session.original, message = err })
    end
    self:_send(session, {
      state = "result",
      original = session.original,
      -- Put back the whitespace around the selection that we didn't send.
      corrected = session.lead .. trim(result.corrected_text) .. session.trail,
      changes = result.changes,
      acceptByDefault = self.acceptByDefault,
    })
  end)
end

---------------------------------------------------------------------------
-- Review panel
---------------------------------------------------------------------------

-- Calls window.proofread.<fn>(payload) in the panel.
function obj:_call(session, fn, payload)
  if not (session.ready and session.webview) then return end
  local ok, json = pcall(hs.json.encode, payload)
  if not ok then
    log.e("Couldn't encode data for the panel: " .. tostring(json))
    return
  end
  session.webview:evaluateJavaScript("window.proofread && window.proofread." .. fn .. "(" .. json .. ")")
end

-- Sends the panel its current state (or remembers it until the panel is ready).
function obj:_send(session, payload)
  payload.model = self.model
  session.payload = payload
  self:_call(session, "update", payload)
end

function obj:_focusPanel(session)
  local webview = session.webview
  if not webview then return end
  webview:show()
  webview:bringToFront()
  hs.focus()
  local window = webview:hswindow()
  if window then window:focus() end
end

function obj:_showPanel(session)
  local html = readFile(spoonPath .. "panel.html")
  if not html then
    hs.alert.show("Proofread: panel.html is missing from the Spoon folder")
    return false
  end

  local screen = (session.win and session.win:screen()) or hs.screen.mainScreen()
  local frame = screen:frame()
  local w = math.min(self.panelSize.w, frame.w - 40)
  local h = math.min(self.panelSize.h, frame.h - 40)
  local rect = { x = frame.x + (frame.w - w) / 2, y = frame.y + (frame.h - h) / 3, w = w, h = h }

  local usercontent = hs.webview.usercontent.new("proofread")
  usercontent:setCallback(function(message)
    -- Hammerspoon passes the WKScriptMessage as a table whose .body is what
    -- the page posted; accept the bare body too, just in case.
    local body = message
    if type(message) == "table" and message.body ~= nil then body = message.body end
    self:_onPanelMessage(session, body)
  end)

  local webview = hs.webview.new(rect, { developerExtrasEnabled = self.debug and true or false }, usercontent)
  local levels = (hs.canvas and hs.canvas.windowLevels) or hs.drawing.windowLevels
  webview:windowTitle("Proofread")
  webview:windowStyle({ "titled", "closable", "resizable" })
  webview:allowTextEntry(true)
  webview:allowNewWindows(false)
  webview:level(levels.floating)
  webview:shadow(true)
  webview:deleteOnClose(true)
  webview:windowCallback(function(action)
    if action == "closing" then
      session.webview = nil -- it deletes itself
      self:_finish(session, "cancel")
    end
  end)
  webview:html(html)

  session.webview = webview
  session.usercontent = usercontent
  webview:show()
  after(0.05, function() self:_focusPanel(session) end)
  return true
end

function obj:_onPanelMessage(session, body)
  if type(body) ~= "table" or session.closed then return end
  local action = body.action
  if action == "ready" then
    session.ready = true
    if session.payload then self:_send(session, session.payload) end
  elseif action == "insert" then
    self:_finish(session, "insert", body.text)
  elseif action == "copy" then
    self:_finish(session, "copy", body.text)
  elseif action == "cancel" then
    self:_finish(session, "cancel")
  elseif action == "retry" then
    self:_send(session, { state = "loading", original = session.original })
    self:_requestCorrections(session)
  elseif action == "getPrompt" then
    self:_sendPrompt(session)
  elseif action == "savePrompt" then
    self:_savePrompt(session, body.text, body.recheck)
  elseif action == "readClipboard" then
    -- For the prompt editor, in case Cmd-V doesn't reach it on its own.
    self:_call(session, "paste", { text = hs.pasteboard.getContents() or "" })
  elseif action == "writeClipboard" then
    if type(body.text) == "string" then hs.pasteboard.setContents(body.text) end
  end
end

-- Closes the panel and carries out the user's choice.
function obj:_finish(session, how, text)
  if session.closed then return end
  session.closed = true
  if self._session == session then self._session = nil end

  local webview = session.webview
  session.webview = nil
  if webview then
    webview:hide()
    after(0, function()
      webview:delete()
      session.usercontent = nil
    end)
  end

  if how == "insert" and type(text) == "string" and text ~= session.original then
    pasteInto(session, text, self.clipboardRestoreDelay)
  elseif how == "copy" and type(text) == "string" then
    hs.pasteboard.setContents(text)
    refocus(session, function() hs.alert.show("Proofread: copied to the clipboard") end)
  else
    restoreIfUntouched(session)
    refocus(session)
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Proofread:proofreadSelection()
--- Method
--- Copies the current selection, asks Claude for corrections and opens the
--- review panel. This is what the hotkey calls.
function obj:proofreadSelection()
  local current = self._session
  if current then
    -- Already running: just bring the open panel forward.
    self:_focusPanel(current)
    return
  end

  if not hs.accessibilityState() then
    hs.accessibilityState(true) -- shows the macOS permission prompt
    hs.alert.show("Proofread needs Accessibility access for Hammerspoon:\nSystem Settings → Privacy & Security → Accessibility", 6)
    return
  end

  local session = {
    app = hs.application.frontmostApplication(),
    win = hs.window.focusedWindow(),
    clipboard = snapshotClipboard(),
  }
  self._session = session

  afterModifiersReleased(function()
    copySelection(function(text, copied)
      if self._session ~= session then return end
      session.expectedChangeCount = hs.pasteboard.changeCount()
      if type(text) ~= "string" or not text:find("%S") then
        self._session = nil
        if copied then restoreClipboard(session.clipboard) end
        hs.alert.show("Proofread: select some text first")
        return
      end
      session.original = text
      -- Only the text itself goes to Claude; surrounding whitespace is kept as is.
      session.lead, session.core, session.trail = text:match("^(%s*)(.-)(%s*)$")
      if not self:_showPanel(session) then
        self._session = nil
        restoreClipboard(session.clipboard)
        return
      end
      self:_send(session, { state = "loading", original = text })
      self:_requestCorrections(session)
    end)
  end)
end

--- Proofread:init()
--- Method
--- Called by hs.loadSpoon. Asks macOS for Accessibility access right away
--- (needed to send Cmd-C and Cmd-V), so the first hotkey press just works.
function obj:init()
  if not hs.accessibilityState() then hs.accessibilityState(true) end
  return self
end

--- Proofread:bindHotkeys(mapping)
--- Method
--- Binds the hotkey. Example:
---   spoon.Proofread:bindHotkeys({ proofread = { { "ctrl", "alt" }, "p" } })
function obj:bindHotkeys(mapping)
  hs.spoons.bindHotkeysToSpec({
    proofread = function() self:proofreadSelection() end,
  }, mapping)
  return self
end

return obj
