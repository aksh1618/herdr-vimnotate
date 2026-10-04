local core = require("vimnotate.core")
local store = require("vimnotate.store")
local A = store.A
local KINDS = core.KINDS

local dw = vim.fn.strdisplaywidth

local function chars(s)
  local out = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = ch
  end
  return out
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
  local out = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local line, lw = "", 0
    for word in para:gmatch("%S+") do
      local ww = dw(word)
      if lw > 0 and lw + 1 + ww <= width then
        line, lw = line .. " " .. word, lw + 1 + ww
      else
        if lw > 0 then
          out[#out + 1] = line
        end
        line, lw = "", 0
        if ww > width then
          for _, ch in ipairs(chars(word)) do
            local cw = dw(ch)
            if lw > 0 and lw + cw > width then
              out[#out + 1] = line
              line, lw = "", 0
            end
            line, lw = line .. ch, lw + cw
          end
        else
          line, lw = word, ww
        end
      end
    end
    out[#out + 1] = line
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
