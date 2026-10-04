local M = require("vimnotate")
local core = require("vimnotate.core")
local chrome = require("vimnotate.chrome")
local B = require("vimnotate.bars")
local boxes = require("vimnotate.boxes")
local rail = require("vimnotate.rail")
local note = core.note
local note_text = core.note_text
local note_shown = core.note_shown
local note_path = core.note_path
local back_to_thread = core.back_to_thread
local refresh_winbar = chrome.refresh_winbar
local hide_chrome = chrome.hide_chrome
local rail_render = rail.render
local bars_hide = B.hide
local dw = boxes.dw
local truncate = boxes.truncate

local Nt = {}

local NOTE_MIN_WIDTH = 40
local NOTE_MAX_WIDTH = 100
local NOTE_MIN_HEIGHT = 6
local NOTE_MAX_HEIGHT = 24
M.NOTE_TITLES = {
  insert = { "note · sent first · esc normal", "note · esc normal" },
  normal = { "note · sent first · q/Tab close · i insert", "note · q/Tab close · i insert", "note · q/Tab close" },
}

local function note_title(width)
  local insert = note_shown() and vim.api.nvim_get_current_win() == note.win and vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  local options = M.NOTE_TITLES[insert and "insert" or "normal"]
  for _, t in ipairs(options) do
    if dw(t) + 2 <= width then
      return " " .. t .. " "
    end
  end
  return truncate(" " .. options[#options] .. " ", width)
end
M.note_title = note_title

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function note_layout()
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.max(1, math.min(cols - 2, clamp(math.floor(cols * 0.7), NOTE_MIN_WIDTH, NOTE_MAX_WIDTH)))
  local height = math.max(1, math.min(rows - 2, clamp(math.floor(rows * 0.45), NOTE_MIN_HEIGHT, NOTE_MAX_HEIGHT)))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((rows - height - 2) / 2)),
    col = math.max(0, math.floor((cols - width - 2) / 2)),
    title = note_title(width),
    title_pos = "left",
  }
end
M.note_layout = note_layout

function M.note_shown()
  return note_shown()
end

function M.note_hide()
  if not note_shown() then
    return
  end
  local win = note.win
  if vim.api.nvim_get_current_win() == win then
    back_to_thread()
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.cmd("stopinsert")
  end
  refresh_winbar()
  rail_render()
end

local function note_keys(buf)
  local o = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", M.note_hide, o)
  vim.keymap.set("n", "<Tab>", M.note_hide, o)
  vim.keymap.set("n", "H", "H", o)
  vim.keymap.set("n", "L", "L", o)
  for _, lhs in ipairs(M.BUFFER_SWITCHERS) do
    vim.keymap.set("n", lhs, "<Nop>", o)
  end
end

function M.note_open()
  if note_shown() then
    vim.api.nvim_set_current_win(note.win)
    return note.win
  end
  bars_hide()
  local fresh = not (note.buf and vim.api.nvim_buf_is_valid(note.buf))
  local buf = note.buf
  if fresh then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
  end
  local cfg = note_layout()
  cfg.border = "rounded"
  cfg.style = "minimal"
  local win = vim.api.nvim_open_win(buf, false, cfg)
  note.win = win
  vim.wo[win].winfixbuf = false
  vim.wo[win].conceallevel = 2
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = "FloatBorder:VimnotateCommentBorder,FloatTitle:VimnotateTitle"
  vim.api.nvim_set_current_win(win)
  if fresh then
    vim.cmd("edit " .. vim.fn.fnameescape(note_path))
    note.buf = vim.api.nvim_get_current_buf()
    chrome.markdown_warm = true
    if vim.bo[note.buf].filetype ~= "markdown" then
      vim.bo[note.buf].filetype = "markdown"
    end
    vim.bo[note.buf].swapfile = false
    vim.bo[note.buf].undofile = false
    vim.bo[note.buf].bufhidden = "hide"
    note_keys(note.buf)
    hide_chrome()
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = vim.api.nvim_create_augroup("vimnotate.note_text", { clear = true }),
      buffer = note.buf,
      callback = function()
        refresh_winbar()
        rail_render()
      end,
    })
  end
  vim.wo[win].winfixbuf = true
  return win
end

function M.note_show()
  if note_shown() then
    vim.api.nvim_set_current_win(note.win)
    return
  end
  local win = M.note_open()
  local lines = vim.api.nvim_buf_get_lines(note.buf, 0, -1, false)
  local last = #lines
  while last > 1 and not lines[last]:find("%S") do
    last = last - 1
  end
  vim.api.nvim_win_set_cursor(win, { last, math.max(#lines[last] - 1, 0) })
  if note_text() == "" then
    vim.cmd("startinsert!")
  end
end

function M.note_toggle()
  if note_shown() then
    M.note_hide()
  else
    M.note_show()
  end
end

function _G.vimnotate_note_click(_, _, button)
  if button == "l" then
    vim.schedule(M.note_show)
  end
end

local function quote_into_note(lines)
  if #lines == 0 then
    return
  end
  local win = M.note_open()
  local content = vim.api.nvim_buf_get_lines(note.buf, 0, -1, false)
  while #content > 0 and content[#content]:match("^%s*$") do
    table.remove(content)
  end
  if #content > 0 then
    content[#content + 1] = ""
  end
  for _, l in ipairs(lines) do
    content[#content + 1] = ("> " .. l):gsub("%s+$", "")
  end
  content[#content + 1] = ""
  content[#content + 1] = ""
  vim.api.nvim_buf_set_lines(note.buf, 0, -1, false, content)
  vim.api.nvim_win_set_cursor(win, { #content, 0 })
  vim.cmd("startinsert")
end

function Nt.setup()
  local note_group = vim.api.nvim_create_augroup("vimnotate.note", { clear = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = note_group,
    callback = function()
      if not note_shown() or vim.api.nvim_get_current_win() ~= note.win then
        return
      end
      vim.schedule(function()
        local cur = vim.api.nvim_get_current_win()
        if note_shown() and cur ~= note.win and vim.api.nvim_win_get_config(cur).relative == "" then
          M.note_hide()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = note_group,
    callback = function()
      if note_shown() then
        vim.api.nvim_win_set_config(note.win, { title = note_title(vim.api.nvim_win_get_width(note.win)), title_pos = "left" })
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = note_group,
    callback = function()
      if note_shown() then
        vim.api.nvim_win_set_config(note.win, note_layout())
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = note_group,
    callback = function(ev)
      if note.win and tonumber(ev.match) == note.win then
        note.win = nil
        vim.schedule(function()
          refresh_winbar()
          rail_render()
        end)
      end
    end,
  })
end

Nt.quote_into_note = quote_into_note

return Nt
