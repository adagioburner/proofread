-- Simulated end-to-end tests for init.lua: runs the Spoon against a fake
-- Hammerspoon (clipboard, keystrokes, apps, timers, panel, HTTP).
-- Run with Lua 5.4 from the repo folder:  lua tests/test_flow.lua
local TESTDIR = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local REPO = TESTDIR .. ".."
local M = loadfile(TESTDIR .. "mock_hs.lua")(TESTDIR, REPO)
local json = M.json()

local failures, passes = {}, 0
local function check(cond, label)
  if cond then passes = passes + 1; print("PASS " .. label)
  else failures[#failures + 1] = label; print("FAIL " .. label) end
end

local function apiOk(result, extra)
  return function(req)
    local resp = { id = "msg_1", type = "message", role = "assistant",
      content = { { type = "text", text = json.encode(result) } }, stop_reason = "end_turn" }
    for k, v in pairs(extra or {}) do resp[k] = v end
    return 200, json.encode(resp)
  end
end

local GOOD = apiOk({ changes = { { original = "dont", replacement = "don't", reason = "Missing apostrophe." } },
                     corrected_text = "I don't know." })

-- Fresh Spoon + fresh simulated Mac for each scenario. Returns the Spoon after
-- the hotkey was pressed with `selection` selected in the editor.
local function start(selection, opts)
  opts = opts or {}
  M.reset()
  M.apps.editor.selection = selection
  M.httpResponder = opts.responder or GOOD
  if opts.setup then opts.setup() end
  local spoon = dofile(REPO .. "/init.lua")
  spoon:bindHotkeys({ proofread = { { "ctrl", "alt" }, "p" } })
  M.modifiersHeld = true                              -- user still holding ctrl+alt
  M.schedule(0.12, function() M.modifiersHeld = false end)
  M.boundSpec.proofread()
  M.run(0.4)                                          -- copy done, panel open, request sent
  return spoon
end

local function openAndAnswer(spoon)
  M.panelPost({ action = "ready" })
  M.run(1.0)                                          -- API answers
  return M.lastPayload()
end

---------------------------------------------------------------- 1. happy path
do
  print("\n== insert accepted changes ==")
  local spoon = start("  I dont know.\n")
  check(M.boundMapping and M.boundMapping.proofread[2] == "p", "hotkey mapping passed to bindHotkeysToSpec")
  local copyKey
  for _, k in ipairs(M.keys) do if k.code == 8 and k.down then copyKey = k end end
  check(copyKey and copyKey.mods == "cmd", "sent Cmd-C (key code 8)")
  check(copyKey and not copyKey.heldMods, "waited for the hotkey's modifiers to be released before Cmd-C")
  local wv = M.webview()
  check(wv ~= nil and wv.shown, "review panel opened")
  check(wv and wv.htmlContent and wv.htmlContent:find("ProofreadCore", 1, true), "panel.html loaded into the panel")
  check(wv and wv.settings.allowTextEntry and wv.settings.allowTextEntry[1] == true, "panel accepts keyboard input")
  check(M.front == M.apps.hammerspoon, "panel took focus")
  check(#wv.js == 0, "nothing sent to the page before it says it's ready")

  check(#M.requests == 1, "one API request sent")
  local req = M.requests[1]
  check(req.url == "https://api.anthropic.com/v1/messages", "posts to the Messages API")
  check(req.headers["x-api-key"] == "sk-ant-test-key" and req.headers["anthropic-version"] == "2023-06-01"
        and req.headers["content-type"] == "application/json", "auth/version/content-type headers set")
  check(M.executed[1]:find("security find-generic-password -s 'proofread-anthropic-api-key' -w", 1, true) ~= nil,
        "API key read from the Keychain")
  local ok, body = pcall(json.decode, req.body)
  check(ok, "request body is valid JSON")
  if ok then
    check(body.model == "claude-sonnet-5-5" and body.max_tokens == 16000, "model and max_tokens")
    check(body.system:sub(1, 30) == "You are a careful copy editor." and not body.system:find("<!--", 1, true),
          "system prompt from prompt.md, comment stripped")
    check(body.messages[1].role == "user" and body.messages[1].content:find("<text>\nI dont know.\n</text>", 1, true),
          "only the trimmed selection is sent, inside <text> tags")
    check(body.output_config.effort == "low", "effort = low")
    local f = body.output_config.format
    check(f.type == "json_schema" and f.schema.required[1] == "changes" and f.schema.additionalProperties == false,
          "structured-output schema attached")
    check(body.tools == nil and body.tool_choice == nil and body.temperature == nil,
          "no forced tool use / temperature (rejected by Sonnet 5.5)")
    check(req.body:find('"changes"', 1, true) < req.body:find('"corrected_text"', 1, true),
          "schema lists changes before corrected_text")
  end

  M.panelPost({ action = "ready" })
  local p = M.lastPayload()
  check(p.state == "loading" and p.original == "  I dont know.\n" and p.model == "claude-sonnet-5-5",
        "page gets the loading state once ready")
  M.run(1.0)
  p = M.lastPayload()
  check(p.state == "result", "page gets the result")
  check(p.corrected == "  I don't know.\n", "whitespace around the selection is preserved in the result")
  check(p.changes[1].reason == "Missing apostrophe." and p.acceptByDefault == true, "notes and settings forwarded")

  M.panelPost({ action = "insert", text = "  I don't know.\n" })
  check(wv.shown == false, "panel hidden on Insert")
  M.run(0.5)
  check(wv.deleted, "panel deleted")
  check(M.front == M.apps.editor, "switched back to the editor")
  check(#M.pasted == 1 and M.pasted[1].app == "Editor" and M.pasted[1].text == "  I don't know.\n",
        "accepted text pasted into the editor")
  M.run(1.0)
  check(M.pb.items["public.utf8-plain-text"] == "OLD CLIPBOARD" and M.pb.items["public.rtf"] == "{\\rtf old}",
        "previous clipboard (all formats) restored after pasting")
  check(spoon._session == nil, "session cleared")
  check(#M.timers == 0, "no timers left running")
end

---------------------------------------------------------------- 2. cancel
do
  print("\n== cancel ==")
  start("I dont know.")
  openAndAnswer()
  M.panelPost({ action = "cancel" })
  M.run(2)
  check(#M.pasted == 0, "nothing pasted")
  check(M.front == M.apps.editor, "editor refocused")
  check(M.pb.items["public.utf8-plain-text"] == "OLD CLIPBOARD" and M.pb.items["public.rtf"], "clipboard restored")
  check(M.webview().deleted, "panel deleted")
end

---------------------------------------------------------------- 3. nothing selected
do
  print("\n== nothing selected ==")
  local spoon = start(nil)
  M.run(2)
  check(#M.webviews == 0, "no panel")
  check(#M.requests == 0, "no API call")
  check(M.alerts[1] and M.alerts[1]:find("select some text", 1, true), "alert: select some text first")
  check(M.pb.items["public.utf8-plain-text"] == "OLD CLIPBOARD", "clipboard untouched")
  check(spoon._session == nil, "ready for the next try")
end

---------------------------------------------------------------- 4. no API key
do
  print("\n== no API key ==")
  start("I dont know.", { setup = function() M.keychainKey = nil end })
  local p = openAndAnswer()
  check(#M.requests == 0, "no API call without a key")
  check(p.state == "error" and p.code:find("security add-generic-password", 1, true), "error shows the Keychain command")
  -- user stores key, presses Try again
  M.keychainKey = "sk-ant-new"
  M.panelPost({ action = "retry" })
  check(M.lastPayload().state == "loading", "retry shows loading")
  M.run(1)
  check(#M.requests == 1 and M.requests[1].headers["x-api-key"] == "sk-ant-new", "retry re-reads the key")
  check(M.lastPayload().state == "result", "retry succeeds")
end

---------------------------------------------------------------- 5. API errors
local function errorCase(label, responder, expect)
  start("I dont know.", { responder = responder })
  local p = openAndAnswer()
  check(p.state == "error" and p.message:find(expect, 1, true), label .. " -> " .. tostring(p.message))
end
do
  print("\n== API errors ==")
  errorCase("401", function() return 401, '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}' end, "rejected your API key")
  errorCase("529", function() return 529, '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' end, "Overloaded")
  errorCase("network", function() return -1, "The Internet connection appears to be offline." end, "Couldn't reach")
  errorCase("max_tokens", apiOk({ changes = {}, corrected_text = "I d" }, { stop_reason = "max_tokens" }), "too long")
  errorCase("refusal", apiOk({ changes = {}, corrected_text = "" }, { stop_reason = "refusal" }), "declined")
  errorCase("garbage", function() return 200, "<html>" end, "unexpected response")
  errorCase("bad JSON text", function() return 200, json.encode({ content = { { type = "text", text = "not json" } }, stop_reason = "end_turn" }) end, "Couldn't read")
  -- thinking blocks before the text block are skipped
  start("I dont know.", { responder = function()
    return 200, json.encode({ content = { { type = "thinking", thinking = "hmm" },
      { type = "text", text = json.encode({ changes = {}, corrected_text = "I don't know." }) } }, stop_reason = "end_turn" })
  end })
  check(openAndAnswer().corrected == "I don't know.", "thinking blocks are ignored")
end

---------------------------------------------------------------- 6. copy
do
  print("\n== copy ==")
  start("I dont know.")
  openAndAnswer()
  M.panelPost({ action = "copy", text = "I don't know." })
  M.run(3)
  check(#M.pasted == 0, "nothing pasted")
  check(M.pb.items["public.utf8-plain-text"] == "I don't know.", "result left on the clipboard")
  check(M.front == M.apps.editor and M.alerts[#M.alerts]:find("copied", 1, true), "editor refocused, alert shown")
end

---------------------------------------------------------------- 7. hotkey while open
do
  print("\n== hotkey pressed again ==")
  start("I dont know.")
  openAndAnswer()
  M.front = M.apps.editor
  M.boundSpec.proofread()
  M.run(1)
  check(#M.webviews == 1 and #M.requests == 1, "no second panel or request")
  check(M.front == M.apps.hammerspoon, "existing panel brought forward")
end

---------------------------------------------------------------- 8. close button
do
  print("\n== window close button ==")
  local spoon = start("I dont know.")
  openAndAnswer()
  local wv = M.webview()
  wv.wcb("closing", wv)      -- the window deletes itself after this
  M.run(2)
  check(not wv.deleted, "doesn't delete a window that is already closing")
  check(M.front == M.apps.editor and M.pb.items["public.utf8-plain-text"] == "OLD CLIPBOARD", "treated as cancel")
  check(spoon._session == nil, "session cleared")
end

---------------------------------------------------------------- 9. cancel while loading
do
  print("\n== cancel before the answer arrives ==")
  local spoon = start("I dont know.")
  M.panelPost({ action = "ready" })
  M.panelPost({ action = "cancel" })
  M.run(3)               -- late response must be ignored without touching the deleted panel
  check(#M.webview().js == 1, "late response ignored")
  check(spoon._session == nil and M.front == M.apps.editor, "back in the editor")
end

---------------------------------------------------------------- 10. nothing accepted
do
  print("\n== Insert with every change rejected ==")
  start("I dont know.")
  openAndAnswer()
  M.panelPost({ action = "insert", text = "I dont know." })
  M.run(3)
  check(#M.pasted == 0, "no paste when nothing changed")
  check(M.pb.items["public.utf8-plain-text"] == "OLD CLIPBOARD", "clipboard restored")
end

---------------------------------------------------------------- 11. no accessibility permission
do
  print("\n== no Accessibility permission ==")
  start("I dont know.", { setup = function() M.axTrusted = false end })
  M.run(2)
  check(#M.keys == 0 and #M.webviews == 0, "does nothing")
  check(M.alerts[1] and M.alerts[1]:find("Accessibility", 1, true), "explains how to grant access")
end

---------------------------------------------------------------- 12. Russian keyboard layout
do
  print("\n== non-Latin keyboard layout ==")
  start("Я не знаю что делать.", { setup = function() hs.keycodes.map = { ["с"] = 8, ["м"] = 9 } end })
  openAndAnswer()
  M.panelPost({ action = "insert", text = "Я не знаю, что делать." })
  M.run(3)
  check(#M.pasted == 1 and M.pasted[1].text == "Я не знаю, что делать.", "copy/paste still work via fallback key codes")
end

---------------------------------------------------------------- 13. custom prompt file + settings
do
  print("\n== settings ==")
  local path = os.tmpname()
  local f = io.open(path, "w"); f:write("<!-- note -->\nBe terse.\n"); f:close()
  start("I dont know.", { setup = function() end })
  -- start() already sent with defaults; make a new run with overrides
  M.reset(); M.apps.editor.selection = "x y"; M.httpResponder = GOOD
  local spoon = dofile(REPO .. "/init.lua")
  spoon.promptFile = path; spoon.model = "claude-haiku-5-5"; spoon.effort = nil; spoon.acceptByDefault = false
  spoon:proofreadSelection(); M.run(0.5)
  local body = json.decode(M.requests[1].body)
  check(body.system == "Be terse." and body.model == "claude-haiku-5-5" and body.output_config.effort == nil,
        "promptFile/model/effort overrides respected")
  M.panelPost({ action = "ready" }); M.run(1)
  check(M.lastPayload().acceptByDefault == false, "acceptByDefault forwarded")
  os.remove(path)
end

---------------------------------------------------------------- 14. prompt editor
local function readAll(path) local f = io.open(path); local c = f:read("a"); f:close(); return c end
local function writeAll(path, c) local f = io.open(path, "w"); f:write(c); f:close() end

do
  print("\n== prompt editor ==")
  local path = os.tmpname()
  writeAll(path, "<!-- note -->\nOld prompt.\n")
  local spoon = start("I dont know.", { setup = function() end })
  spoon.promptFile = path            -- never touch the repo's prompt.md in tests
  openAndAnswer()

  M.panelPost({ action = "getPrompt" })
  local p = M.lastCall("showPrompt")
  check(p and p.text == "<!-- note -->\nOld prompt.\n" and p.committed == nil and p.error == nil,
        "getPrompt sends the file's text (no git history for a custom promptFile)")

  M.panelPost({ action = "savePrompt", text = "<!-- note -->\nNew prompt.", recheck = false })
  check(readAll(path) == "<!-- note -->\nNew prompt.\n", "savePrompt writes the file (with a final newline)")
  local saved = M.lastCall("promptSaved")
  check(saved.ok == true and saved.recheck == false and saved.text == "<!-- note -->\nNew prompt.\n", "panel told the save worked")
  check(#M.requests == 1, "plain save doesn't re-run")

  M.panelPost({ action = "savePrompt", text = "Newer prompt.\n", recheck = true })
  check(M.lastCall("promptSaved").recheck == true, "save & re-check acknowledged")
  check(M.lastPayload().state == "loading", "re-check shows loading")
  check(#M.requests == 2 and json.decode(M.requests[2].body).system == "Newer prompt.", "re-check uses the new prompt")
  M.run(1)
  check(M.lastPayload().state == "result", "re-check result delivered")

  spoon.promptFile = "/nonexistent-dir/prompt.md"
  M.panelPost({ action = "savePrompt", text = "x", recheck = true })
  local failed = M.lastCall("promptSaved")
  check(failed.ok == false and failed.error:find("Couldn't save", 1, true), "unwritable file -> error, no re-run")
  check(#M.requests == 2, "failed save doesn't re-run")
  os.remove(path)
end

do
  print("\n== prompt history from git ==")
  local spoon = start("I dont know.")
  openAndAnswer()
  local committed = spoon:_committedPrompt()
  check(type(committed) == "string" and committed:find("careful copy editor", 1, true),
        "committed prompt.md read with git show HEAD:prompt.md")
  M.panelPost({ action = "getPrompt" })
  local p = M.lastCall("showPrompt")
  check(p.text == readAll(REPO .. "/prompt.md") and p.committed == committed, "getPrompt includes the committed version")
  check(p.path:sub(-23) == "/Proofread.spoon/prompt.md" or p.path:sub(-9) == "prompt.md", "path shown")
end

do
  print("\n== editor clipboard bridge ==")
  start("I dont know.")
  openAndAnswer()
  M.panelPost({ action = "readClipboard" })
  check(M.lastCall("paste").text == "I dont know.", "readClipboard returns the clipboard text")
  M.panelPost({ action = "writeClipboard", text = "copied in the editor" })
  M.panelPost({ action = "cancel" })
  M.run(2)
  check(M.pb.items["public.utf8-plain-text"] == "copied in the editor", "text copied in the editor survives closing the panel")
end

do
  print("\n== user copies something while the panel is open ==")
  start("I dont know.")
  openAndAnswer()
  hs.pasteboard.setContents("copied from another app")
  M.panelPost({ action = "cancel" })
  M.run(2)
  check(M.pb.items["public.utf8-plain-text"] == "copied from another app", "their new clipboard isn't overwritten")
end

do
  print("\n== asks for Accessibility when loaded ==")
  M.reset(); M.axTrusted = false
  local spoon = dofile(REPO .. "/init.lua"); spoon:init()
  check(M.axPrompted, "init() shows the macOS permission prompt when access is missing")
  M.reset()
  spoon = dofile(REPO .. "/init.lua"); spoon:init()
  check(not M.axPrompted, "no prompt when access is already granted")
end

print(("\n%d passed, %d failed"):format(passes, #failures))
for _, f in ipairs(failures) do print("  FAILED: " .. f) end
if #failures > 0 then error("tests failed") end
