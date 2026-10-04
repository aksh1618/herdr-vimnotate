local M = require("vimnotate")
local core = require("vimnotate.core")
local store = require("vimnotate.store")
local A = store.A
local H = store.H
local thread = core.thread
local KINDS = core.KINDS
local warn = core.warn
local line_len = core.line_len
local single_line = core.single_line
local state_path = core.state_path

local Rs = {}

local hay = nil

local function find_all(text)
  local needle = text:gsub("%s+", "")
  if needle == "" then
    return {}, 0
  end
  if not hay then
    local chars_, rows, cols = {}, {}, {}
    for r, l in ipairs(vim.api.nvim_buf_get_lines(thread, 0, -1, false)) do
      for pos, ch in l:gmatch("()(%S)") do
        chars_[#chars_ + 1] = ch
        rows[#rows + 1] = r - 1
        cols[#cols + 1] = pos - 1
      end
    end
    hay = { s = table.concat(chars_), rows = rows, cols = cols }
  end
  local out, init = {}, 1
  while true do
    local s = hay.s:find(needle, init, true)
    if not s then
      break
    end
    local e = s + #needle - 1
    out[#out + 1] = {
      srow = hay.rows[s],
      scol = hay.cols[s],
      erow = hay.rows[e],
      ecol = hay.cols[e] + 1,
      linewise = false,
      full = (s == 1 or hay.rows[s - 1] ~= hay.rows[s]) and (e == #hay.rows or hay.rows[e + 1] ~= hay.rows[e]),
    }
    init = s + 1
  end
  return out, vim.fn.strchars(needle)
end

local function candidates(text, linewise)
  local found, len = find_all(text)
  if not linewise then
    return found, len
  end
  return vim.tbl_filter(function(r)
    return r.full
  end, found), len
end

local CONTEXT_LINES = 5
local CONTEXT_CHARS = 200

local function context(row, step)
  local out, total = {}, 0
  local last = vim.api.nvim_buf_line_count(thread) - 1
  while row >= 0 and row <= last and #out < CONTEXT_LINES and total < CONTEXT_CHARS do
    local l = single_line(vim.api.nvim_buf_get_lines(thread, row, row + 1, false)[1] or "")
    if l ~= "" then
      out[#out + 1] = l
      total = total + #(l:gsub("%s", ""))
    end
    row = row + step
  end
  return out
end

local function context_score(saved, got)
  local score = 0
  if type(saved) ~= "table" then
    return 0
  end
  for i, l in ipairs(saved) do
    if got[i] ~= l then
      break
    end
    score = score + #l
  end
  return score
end

local STATE_VERSION = 1
local target_pane = vim.env.VIMNOTATE_TARGET_PANE or ""
local server = vim.env.VIMNOTATE_SERVER or ""
local carried = {}

local function entry(item)
  local r = A.range(item)
  local text = table.concat(A.text(item), "\n")
  local occ
  for i, c in ipairs((candidates(text, item.linewise))) do
    if c.srow > r.srow or (c.srow == r.srow and c.scol >= r.scol) then
      occ = i
      break
    end
  end
  return {
    kind = item.kind,
    body = item.body,
    text = text,
    linewise = item.linewise,
    before = context(r.srow - 1, -1),
    after = context(r.erow + 1, 1),
    occ = occ,
  }
end

local function entry_key(e)
  return vim.json.encode({ e.kind, e.body, e.text, e.linewise and true or false, e.before or {}, e.after or {}, e.occ or 0 })
end

local function save_state()
  if not state_path then
    return
  end
  local items, seen = {}, {}
  local function push(e)
    local k = entry_key(e)
    if not seen[k] then
      seen[k] = true
      items[#items + 1] = e
    end
  end
  for _, item in ipairs(A.list()) do
    push(entry(item))
  end
  for _, e in ipairs(carried) do
    push(e)
  end
  local dir = vim.fn.fnamemodify(state_path, ":h")
  pcall(vim.fn.mkdir, dir, "p", 448)
  vim.uv.fs_chmod(dir, 448)
  local tmp = state_path .. ".tmp." .. vim.fn.getpid()
  local fd = vim.uv.fs_open(tmp, "w", 384)
  if not fd then
    return
  end
  vim.uv.fs_fchmod(fd, 384)
  local data = vim.json.encode({ version = STATE_VERSION, server = server, pane = target_pane, items = items })
  local wrote = vim.uv.fs_write(fd, data)
  local closed = vim.uv.fs_close(fd)
  if wrote ~= #data or not closed or not vim.uv.fs_rename(tmp, state_path) then
    os.remove(tmp)
  end
end

local function find_in_thread(text)
  local all = find_all(text)
  return all[#all]
end
M.find_in_thread = find_in_thread

local RESTORE_MIN_CHARS = 8

local function read_state()
  local fh = io.open(state_path, "rb")
  if not fh then
    return nil
  end
  local raw = fh:read("*a")
  fh:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
    return nil
  end
  if data.version ~= STATE_VERSION or data.pane ~= target_pane or data.server ~= server then
    return nil
  end
  local items, seen = {}, {}
  for _, e in ipairs(data.items) do
    if type(e) == "table" and type(e.text) == "string" and KINDS[e.kind] then
      e.body = type(e.body) == "string" and e.body or ""
      e.linewise = e.linewise == true
      e.before = type(e.before) == "table" and e.before or {}
      e.after = type(e.after) == "table" and e.after or {}
      e.occ = type(e.occ) == "number" and e.occ or nil
      local k = entry_key(e)
      if not seen[k] then
        seen[k] = true
        items[#items + 1] = e
      end
    end
  end
  return items
end

local function locate(saved, taken)
  local found, len = candidates(saved.text, saved.linewise)
  local best, best_score, best_dist
  for i, r in ipairs(found) do
    if saved.linewise then
      r.linewise, r.scol, r.ecol = true, 0, line_len(r.erow)
    end
    local key = table.concat({ r.srow, r.scol, r.erow, r.ecol, saved.kind, saved.body }, "\0")
    if not taken[key] then
      local sc = context_score(saved.before, context(r.srow - 1, -1)) + context_score(saved.after, context(r.erow + 1, 1))
      if sc > 0 or (r.full and len >= RESTORE_MIN_CHARS) then
        local dist = saved.occ and math.abs(i - saved.occ) or 0
        if not best or sc > best_score or (sc == best_score and dist <= best_dist) then
          r.key = key
          best, best_score, best_dist = r, sc, dist
        end
      end
    end
  end
  return best
end

local function restore_sent()
  if not state_path then
    return
  end
  local items = read_state()
  if not items then
    return
  end
  if vim.env.VIMNOTATE_RESTORE == "false" then
    carried = items
    return
  end
  local restored, missing, taken = 0, 0, {}
  H.muted = true
  local ok, err = pcall(function()
    for _, saved in ipairs(items) do
      local r = locate(saved, taken)
      if r then
        taken[r.key] = true
        A.add({ srow = r.srow, scol = r.scol, erow = r.erow, ecol = r.ecol, linewise = r.linewise, kind = saved.kind, body = saved.body, sent = true })
        restored = restored + 1
      else
        carried[#carried + 1] = saved
        missing = missing + 1
      end
    end
  end)
  H.muted = false
  if not ok then
    warn("vimnotate restore: " .. tostring(err))
  end
  if restored + missing > 0 then
    M.flash("restored " .. restored .. " sent" .. (missing > 0 and (", " .. missing .. " not found") or ""))
  end
end

Rs.save_state = save_state
Rs.restore_sent = restore_sent
Rs.find_in_thread = find_in_thread

return Rs
