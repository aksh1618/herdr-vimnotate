local core = require("vimnotate.core")
local store = require("vimnotate.store")
local A = store.A
local KINDS = core.KINDS

local dw = vim.fn.strdisplaywidth

local function chars(s)
  return vim.fn.split(s, "\\zs")
end

local function truncate(s, width)
  if dw(s) <= width then
    return s
  end
  local out, w = {}, 0
  for _, ch in ipairs(chars(s)) do
    local cw = dw(ch)
    if w + cw > width - 1 then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out) .. "…"
end

local function wrap_text(text, width)
  width = math.max(width, 1)
  local ts = math.max(vim.go.tabstop, 1)
  local brk = {}
  for ch in vim.go.breakat:gmatch(".") do
    brk[ch] = true
  end
  local out = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local cs = chars(para)
    local lead = 1
    while cs[lead] and brk[cs[lead]] do
      lead = lead + 1
    end
    local row, col, base = {}, 0, 0
    local function size(ch, at)
      if ch == "\t" then
        return ts - (base + at) % ts
      end
      return dw(ch)
    end
    local function newline()
      out[#out + 1] = table.concat(row)
      row, col, base = {}, 0, base + width
    end
    for i, ch in ipairs(cs) do
      local w = size(ch, col)
      if ch ~= "\t" and col > 0 and col + w > width then
        row[#row + 1] = string.rep(">", width - col)
        newline()
      end
      local wrap = false
      if i > lead and brk[ch] and cs[i + 1] and not brk[cs[i + 1]] then
        local col2 = col
        local j = i + 1
        while cs[j] and (brk[cs[j]] or j == i + 1 or not brk[cs[j - 1]]) do
          col2 = col2 + size(cs[j], col2)
          if col2 >= width - (w - 1) then
            wrap = true
            break
          end
          j = j + 1
        end
      end
      if wrap then
        row[#row + 1] = ch == "\t" and "" or ch
        row[#row + 1] = string.rep(" ", width - col - (ch == "\t" and 0 or w))
        newline()
      elseif ch == "\t" then
        while col + w > width do
          row[#row + 1] = string.rep(" ", width - col)
          w = w - (width - col)
          newline()
        end
        row[#row + 1] = string.rep(" ", w)
        col = col + w
      else
        row[#row + 1] = ch
        col = col + w
      end
    end
    out[#out + 1] = table.concat(row)
  end
  return out
end

local function accent_of(item)
  return "Vimnotate" .. KINDS[item.kind].hl:sub(10) .. "Border" .. (item.sent and "Sent" or "")
end

local function frame(title, accent, lines, text_hl, width, edge, fit)
  if fit then
    local w = dw(title) + 4
    for _, l in ipairs(lines) do
      w = math.max(w, dw(l) + 4)
    end
    width = math.min(width, w)
  end
  title = truncate(title, width - 2)
  local tw = dw(title)
  local rows = { { { "╭", edge }, { title, accent }, { string.rep("─", width - 2 - tw) .. "╮", edge } } }
  for _, l in ipairs(lines) do
    l = truncate(l, width - 4)
    rows[#rows + 1] = { { "│ ", edge }, { l .. string.rep(" ", width - 4 - dw(l)), text_hl }, { " │", edge } }
  end
  rows[#rows + 1] = { { "╰" .. string.rep("─", width - 2) .. "╯", edge } }
  return rows
end

local function bubble(item, width, edge, fit)
  local kind = KINDS[item.kind]
  local title = " " .. kind.glyph .. " " .. A.short_id(item.id) .. (item.sent and " · sent " or " ")
  local body = vim.trim(item.body)
  local lines, text_hl = { kind.label }, "VimnotateLabel"
  if body ~= "" then
    lines, text_hl = wrap_text(body, width - 4), nil
    if #lines > #vim.split(body, "\n", { plain = true }) then
      fit = false
    end
  end
  return frame(title, accent_of(item), lines, text_hl, width, edge, fit)
end

local function cut_rows(b, avail, width)
  local cut = { b[1] }
  for i = 2, avail - 2 do
    cut[#cut + 1] = b[i]
  end
  local last = b[avail - 1]
  cut[#cut + 1] = { last[1], { "…" .. string.rep(" ", width - 5), last[2][2] }, last[3] }
  cut[#cut + 1] = b[#b]
  return cut
end

return {
  dw = dw,
  chars = chars,
  truncate = truncate,
  wrap_text = wrap_text,
  accent_of = accent_of,
  frame = frame,
  bubble = bubble,
  cut_rows = cut_rows,
}
