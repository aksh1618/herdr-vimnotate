local ansi = require("vimnotate.ansi")

local C = {}

local raw_path = vim.env.VIMNOTATE_RAW
local reply_path = vim.env.VIMNOTATE_REPLY
local state_path = vim.env.VIMNOTATE_STATE ~= "" and vim.env.VIMNOTATE_STATE or nil
local note_path = vim.fn.fnamemodify(reply_path, ":h") .. "/note.md"
C.raw_path = raw_path
C.reply_path = reply_path
C.state_path = state_path
C.note_path = note_path

local note = { buf = nil, win = nil }
C.note = note

vim.o.swapfile = false
vim.o.undofile = false
vim.o.mouse = "a"
vim.o.laststatus = 0
vim.o.autowriteall = true

local f = assert(io.open(raw_path, "rb"))
local raw = f:read("*a")
f:close()

local text_lines, line_spans = ansi.parse(raw)

local thread = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(thread)
vim.api.nvim_buf_set_lines(thread, 0, -1, false, text_lines)
local ns = vim.api.nvim_create_namespace("vimnotate")
for row, spans in ipairs(line_spans) do
  for _, sp in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(thread, ns, row - 1, sp[1], { end_col = sp[2], hl_group = sp[3] })
  end
end
vim.bo[thread].modifiable = false
C.thread = thread

local function tint_winbar(win)
  local keep = {}
  for pair in vim.wo[win].winhighlight:gmatch("[^,]+") do
    local from = pair:match("^([^:]+):")
    if from ~= "WinBar" and from ~= "WinBarNC" then
      keep[#keep + 1] = pair
    end
  end
  keep[#keep + 1] = "WinBar:VimnotateWinbar"
  keep[#keep + 1] = "WinBarNC:VimnotateWinbar"
  vim.wo[win].winhighlight = table.concat(keep, ",")
end
C.tint_winbar = tint_winbar

local function scrub_win(win)
  if win == -1 then
    return
  end
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = false
  vim.wo[win].breakindent = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].colorcolumn = ""
  vim.wo[win].fillchars = "eob: "
  tint_winbar(win)
  vim.wo[win].winfixbuf = vim.v.vim_did_enter == 1
end
scrub_win(vim.api.nvim_get_current_win())
vim.cmd("normal! G")
vim.cmd("clearjumps")
C.scrub_win = scrub_win

local function thread_win()
  return vim.fn.bufwinid(thread)
end
C.thread_win = thread_win

function C.note_text()
  if note.buf and vim.api.nvim_buf_is_valid(note.buf) then
    return vim.trim(table.concat(vim.api.nvim_buf_get_lines(note.buf, 0, -1, false), "\n"))
  end
  return ""
end

function C.note_shown()
  return note.win ~= nil and vim.api.nvim_win_is_valid(note.win)
end

function C.warn(msg)
  vim.api.nvim_echo({ { msg, "WarningMsg" } }, false, {})
end

C.KINDS = {
  comment = { glyph = "💬", label = "comment", priority = 0, hl = "VimnotateComment", mark = "VimnotateCommentMark" },
  good = { glyph = "👍", label = "looks good", priority = 1, hl = "VimnotateGood", mark = "VimnotateGoodMark" },
  delete = { glyph = "❌", label = "delete this", priority = 2, hl = "VimnotateDelete", mark = "VimnotateDeleteMark" },
}

C.view = { mode = "off", bubbles = {}, setting = vim.env.VIMNOTATE_VIEW }

function C.line_len(row)
  return #(vim.api.nvim_buf_get_lines(thread, row, row + 1, false)[1] or "")
end

function C.before(a, b)
  if a.srow ~= b.srow then
    return a.srow < b.srow
  end
  return a.scol < b.scol
end

function C.single_line(text)
  return vim.trim(text:gsub("%s+", " "))
end

function C.back_to_thread()
  local tw = thread_win()
  if tw ~= -1 then
    vim.api.nvim_set_current_win(tw)
  end
end

return C
