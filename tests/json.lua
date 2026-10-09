-- Minimal JSON for the test double of hs.json
local json = {}
local function esc(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return m[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end
local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if math.type(k) ~= "integer" or k < 1 then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true, n
end
function json.encode(v)
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then return math.type(v) == "integer" and string.format("%d", v) or string.format("%.14g", v)
  elseif t == "string" then return esc(v)
  elseif t == "table" then
    local arr, n = isArray(v)
    if arr and n > 0 then
      local out = {}
      for i = 1, n do out[i] = json.encode(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    if next(v) == nil then return "[]" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = esc(k) .. ":" .. json.encode(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("cannot encode " .. t)
end
function json.decode(s)
  local pos = 1
  local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local value
  local function str()
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then error("unterminated string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if e == "u" then
          local cp = tonumber(s:sub(pos + 2, pos + 5), 16); pos = pos + 6
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(s:sub(pos + 2, pos + 5), 16); pos = pos + 6
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
          end
          out[#out + 1] = utf8.char(cp)
        else
          out[#out + 1] = map[e] or error("bad escape"); pos = pos + 2
        end
      else
        out[#out + 1] = c; pos = pos + 1
      end
    end
    return table.concat(out)
  end
  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1; local t = {}
      ws(); if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
      while true do
        ws(); local k = str(); ws()
        if s:sub(pos, pos) ~= ":" then error("expected : at " .. pos) end
        pos = pos + 1; t[k] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return t elseif d ~= "," then error("expected , or } at " .. pos) end
      end
    elseif c == "[" then
      pos = pos + 1; local t = {}
      ws(); if s:sub(pos, pos) == "]" then pos = pos + 1; return t end
      while true do
        t[#t + 1] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return t elseif d ~= "," then error("expected , or ] at " .. pos) end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then error("unexpected '" .. c .. "' at " .. pos) end
      pos = pos + #num; return tonumber(num)
    end
  end
  local v = value(); ws()
  if pos <= #s then error("trailing data at " .. pos) end
  return v
end
return json
