local M = require("vimnotate")
local core = require("vimnotate.core")
local store = require("vimnotate.store")
local bars = require("vimnotate.bars")
local A = store.A
local thread = core.thread
local thread_win = core.thread_win
local KINDS = core.KINDS
local warn = core.warn
local line_len = core.line_len
local before = core.before
local hint_hide = bars.hint_hide

local Op = {}

local function op_range(type)
  local s = vim.api.nvim_buf_get_mark(thread, "[")
  local e = vim.api.nvim_buf_get_mark(thread, "]")
  local r = { srow = s[1] - 1, scol = s[2], erow = e[1] - 1 }
  if type == "line" then
    r.linewise = true
    r.scol = 0
    r.ecol = line_len(r.erow)
    return r
  end
  local line = vim.api.nvim_buf_get_lines(thread, r.erow, r.erow + 1, false)[1] or ""
  if e[2] < #line then
    r.ecol = e[2] + vim.str_utf_end(line, e[2] + 1) + 1
  else
    r.ecol = #line
  end
  r.scol = math.min(r.scol, line_len(r.srow))
  r.linewise = false
  if r.srow == r.erow and r.ecol <= r.scol then
    r.linewise = true
    r.scol = 0
    r.ecol = line_len(r.erow)
  end
  return r
end

local OPFUNCS = { comment = "op_comment", good = "op_good", delete = "op_delete" }
local fresh = false
local replaying = false
local recording = nil
local recorder = vim.api.nvim_create_namespace("vimnotate.recorder")

local function shape_keys(r)
  if r.linewise then
    return "g@" .. (r.erow > r.srow and (r.erow - r.srow) .. "j" or "_")
  end
  local last = vim.api.nvim_buf_get_lines(thread, r.erow, r.erow + 1, false)[1] or ""
  if r.erow == r.srow then
    local n = vim.fn.strchars(last:sub(r.scol + 1, r.ecol))
    return "v" .. (n > 1 and (n - 1) .. "l" or "") .. "g@"
  end
  local n = vim.fn.strchars(last:sub(1, r.ecol))
  return "v" .. (r.erow - r.srow) .. "j0" .. (n > 1 and (n - 1) .. "l" or "") .. "g@"
end

function M.restore_repeat()
  local op = M.last_op
  local tw = thread_win()
  if not op or tw == -1 then
    return
  end
  vim.api.nvim_win_call(tw, function()
    local cur = vim.api.nvim_win_get_cursor(tw)
    vim.o.operatorfunc = "v:lua.require'vimnotate'." .. op.func
    replaying = true
    pcall(vim.cmd.normal, { op.keys, bang = op.bang })
    replaying = false
    vim.api.nvim_win_set_cursor(tw, cur)
  end)
end

local function apply_op(kind, type)
  vim.on_key(nil, recorder)
  if replaying then
    return
  end
  local r = op_range(type)
  local was_fresh = fresh
  fresh = false
  if recording then
    local motion = table.concat(recording.keys)
    local recorded = not recording.visual and motion ~= ""
    local keys = recorded and ((recording.count > 0 and recording.count or "") .. "g@" .. motion) or shape_keys(r)
    M.last_op = { kind = kind, func = OPFUNCS[kind], keys = keys, bang = not recorded }
    recording = nil
  end
  local text = r.linewise and vim.api.nvim_buf_get_lines(thread, r.srow, r.erow + 1, false)
    or vim.api.nvim_buf_get_text(thread, r.srow, r.scol, r.erow, r.ecol, {})
  if not table.concat(text, ""):find("%S") then
    warn("nothing to annotate here")
    return
  end
  local function same(item)
    local o = A.range(item)
    return o.linewise == r.linewise and o.srow == r.srow and o.erow == r.erow and (r.linewise or (o.scol == r.scol and o.ecol == r.ecol))
  end
  local rekind
  for _, item in pairs(A.items) do
    if same(item) then
      if item.kind == kind then
        rekind = nil
        if kind ~= "comment" then
          if item.sent then
            A.update(item.id, { sent = false })
          end
          return
        end
        break
      elseif item.sent then
        rekind = item
      end
    end
  end
  if rekind then
    if kind == "comment" then
      M.compose({ item = rekind, kind = kind })
    else
      A.update(rekind.id, { kind = kind })
    end
    return
  end
  if kind == "comment" then
    M.compose({ range = r, body = (not was_fresh) and M.last_body or nil })
    return
  end
  r.kind = kind
  A.add(r)
end

for kind, name in pairs(OPFUNCS) do
  M[name] = function(type)
    apply_op(kind, type)
  end
end

local function operator(kind, suffix)
  return function()
    fresh = true
    local rec = { keys = {}, count = vim.v.count, visual = vim.fn.mode():find("^[vV\22]") ~= nil, first = true }
    recording = rec
    vim.on_key(function(_, typed)
      if recording ~= rec then
        return
      end
      if rec.first then
        rec.first = false
      elseif typed and typed ~= "" then
        rec.keys[#rec.keys + 1] = typed
      end
    end, recorder)
    vim.o.operatorfunc = "v:lua.require'vimnotate'." .. OPFUNCS[kind]
    return "g@" .. (suffix or "")
  end
end

local function line_motion(kind, key)
  return function()
    if vim.v.operator == "g@" and vim.o.operatorfunc:find(OPFUNCS[kind], 1, true) then
      return "_"
    end
    return key
  end
end

function M.jump(dir, count)
  local items = A.list()
  if #items == 0 then
    warn("no annotations")
    return
  end
  local tw = thread_win()
  vim.api.nvim_win_call(tw, function()
    vim.cmd("normal! m'")
  end)
  for _ = 1, count or 1 do
    local cur = vim.api.nvim_win_get_cursor(tw)
    local pos = { srow = cur[1] - 1, scol = cur[2] }
    local target
    if dir > 0 then
      for _, item in ipairs(items) do
        local r = A.range(item)
        if before(pos, r) then
          target = r
          break
        end
      end
      target = target or A.range(items[1])
    else
      for i = #items, 1, -1 do
        local r = A.range(items[i])
        if before(r, pos) then
          target = r
          break
        end
      end
      target = target or A.range(items[#items])
    end
    vim.api.nvim_win_set_cursor(tw, { target.srow + 1, target.linewise and 0 or target.scol })
  end
end

function M.hover()
  hint_hide()
  local item = A.at_cursor()
  if not item then
    warn("no annotation under cursor")
    return
  end
  local kind = KINDS[item.kind]
  local body = vim.trim(item.body)
  local lines = body ~= "" and vim.split(body, "\n", { plain = true }) or { "_(no note)_" }
  vim.lsp.util.open_floating_preview(lines, "markdown", {
    border = "rounded",
    title = " " .. kind.glyph .. " " .. A.short_id(item.id) .. " · " .. kind.label .. (item.sent and " · sent " or " "),
    focus_id = "vimnotate_hover",
    max_width = 60,
  })
end

function M.edit()
  local item = A.at_cursor()
  if not item then
    warn("no annotation under cursor")
    return
  end
  M.compose({ item = item })
end

function M.remove_at_cursor()
  local item = A.at_cursor()
  if not item then
    warn("no annotation under cursor")
    return
  end
  A.remove(item.id)
end

function M.jumplist(dir, count)
  local tw = thread_win()
  if tw == -1 then
    return
  end
  vim.api.nvim_win_call(tw, function()
    pcall(vim.cmd, "normal! " .. (count or 1) .. (dir < 0 and "\15" or "\t"))
  end)
end

Op.operator = operator
Op.line_motion = line_motion

return Op
