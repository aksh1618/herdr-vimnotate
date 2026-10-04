local ansi = {}

local function apply_sgr(attrs, params)
  local parts = vim.split(params:gsub(":", ";"), ";", { plain = true })
  local i = 1
  while i <= #parts do
    local n = tonumber(parts[i]) or 0
    if n == 0 then
      attrs = {}
    elseif n == 1 then
      attrs.bold = true
    elseif n == 3 then
      attrs.italic = true
    elseif n == 4 then
      attrs.underline = true
    elseif n == 22 then
      attrs.bold = nil
    elseif n == 23 then
      attrs.italic = nil
    elseif n == 24 then
      attrs.underline = nil
    elseif n >= 30 and n <= 37 then
      attrs.fg = n - 30
    elseif n == 39 then
      attrs.fg = nil
    elseif n >= 40 and n <= 47 then
      attrs.bg = n - 40
    elseif n == 49 then
      attrs.bg = nil
    elseif n >= 90 and n <= 97 then
      attrs.fg = n - 90 + 8
    elseif n >= 100 and n <= 107 then
      attrs.bg = n - 100 + 8
    elseif n == 38 or n == 48 then
      local key = n == 38 and "fg" or "bg"
      if parts[i + 1] == "2" then
        attrs[key] = string.format(
          "#%02x%02x%02x",
          tonumber(parts[i + 2]) or 0,
          tonumber(parts[i + 3]) or 0,
          tonumber(parts[i + 4]) or 0
        )
        i = i + 4
      elseif parts[i + 1] == "5" then
        attrs[key] = tonumber(parts[i + 2]) or 0
        i = i + 2
      end
    end
    i = i + 1
  end
  return attrs
end

local function color_val(c)
  if type(c) == "string" then
    return c
  end
  if type(c) == "number" and c < 16 then
    return vim.g["terminal_color_" .. c]
  end
  return nil
end

local hl_cache = {}
local function hl_for(attrs)
  if not next(attrs) then
    return nil
  end
  local key = table.concat({
    tostring(attrs.fg or ""),
    tostring(attrs.bg or ""),
    attrs.bold and "b" or "",
    attrs.italic and "i" or "",
    attrs.underline and "u" or "",
  }, "_")
  if not hl_cache[key] then
    local name = "Vimnotate" .. key:gsub("[^%w]", "x")
    vim.api.nvim_set_hl(0, name, {
      fg = color_val(attrs.fg),
      bg = color_val(attrs.bg),
      bold = attrs.bold or false,
      italic = attrs.italic or false,
      underline = attrs.underline or false,
    })
    hl_cache[key] = name
  end
  return hl_cache[key]
end

function ansi.parse(raw)
  raw = raw:gsub("\27%][^\7\27]*\7", ""):gsub("\27%][^\27]*\27\\", ""):gsub("\r\n", "\n"):gsub("\r", "")
  local text_lines = {}
  local line_spans = {}
  local attrs = {}
  for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
    local out = {}
    local byte = 0
    local spans = {}
    local pos = 1
    while true do
      local s, e, params, final = line:find("\27%[([%d;:]*)(%a)", pos)
      local chunk = line:sub(pos, s and s - 1 or #line)
      chunk = chunk:gsub("[%c\27]", "")
      if #chunk > 0 then
        out[#out + 1] = chunk
        local group = hl_for(attrs)
        if group then
          spans[#spans + 1] = { byte, byte + #chunk, group }
        end
        byte = byte + #chunk
      end
      if not s then
        break
      end
      if final == "m" then
        attrs = apply_sgr(attrs, params)
      end
      pos = e + 1
    end
    text_lines[#text_lines + 1] = table.concat(out)
    line_spans[#line_spans + 1] = spans
  end
  return text_lines, line_spans
end

return ansi
