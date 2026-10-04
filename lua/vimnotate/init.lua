local M = {}
package.loaded["vimnotate"] = M

local core = require("vimnotate.core")
M.thread = core.thread
M.thread_win = core.thread_win
M.KINDS = core.KINDS
M.view = core.view

require("vimnotate.highlights").setup()
local store = require("vimnotate.store")
store.setup()
local chrome = require("vimnotate.chrome")
chrome.setup()
require("vimnotate.compose")
require("vimnotate.bars").setup()
require("vimnotate.ops").setup()
require("vimnotate.boxes")
require("vimnotate.rail")
require("vimnotate.view").setup()
local note = require("vimnotate.note")
note.setup()
local restore = require("vimnotate.restore")
require("vimnotate.send").setup()
require("vimnotate.keys").setup()

local thread_win = core.thread_win
local scrub_win = core.scrub_win
local hide_chrome = chrome.hide_chrome
local prewarm_markdown = chrome.prewarm_markdown
local unshadow_triggers = chrome.unshadow_triggers
local thread_winbar = chrome.thread_winbar
local apply_view = M.apply_view
local find_in_thread = restore.find_in_thread
local quote_into_note = note.quote_into_note

unshadow_triggers()

vim.wo.winbar = thread_winbar()
hide_chrome()

restore.restore_sent()
apply_view()

local CLIPBOARD_MIN_CHARS = 8

local function read_anchor_file(path)
  if not path or path == "" then
    return ""
  end
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local text = f:read("*a"):gsub("%s+$", "")
  f:close()
  return text
end

local anchored = false
local function anchor(r)
  anchored = true
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { r.srow + 1, r.scol })
  vim.cmd("normal! zz")
  M.compose({ range = r })
end

local selected = read_anchor_file(vim.env.VIMNOTATE_SELECTED)
if selected ~= "" then
  local r = find_in_thread(selected)
  if r then
    anchor(r)
  else
    quote_into_note(vim.split(selected, "\n", { plain = true }))
  end
else
  local clip_path = vim.env.VIMNOTATE_CLIPBOARD
  local clip = read_anchor_file(clip_path)
  if clip_path and clip_path ~= "" then
    os.remove(clip_path)
  end
  if vim.fn.strchars((clip:gsub("%s", ""))) >= CLIPBOARD_MIN_CHARS then
    local r = find_in_thread(clip)
    if r then
      anchor(r)
      local used = io.open(clip_path .. ".used", "wb")
      if used then
        used:close()
      end
    end
  end
end

vim.defer_fn(function()
  hide_chrome()
  prewarm_markdown()
  unshadow_triggers()
  local tw = thread_win()
  if tw ~= -1 then
    scrub_win(tw)
    vim.wo[tw].winbar = thread_winbar()
    M.rail_scrub()
    apply_view()
    if not anchored then
      vim.api.nvim_win_call(tw, function()
        vim.cmd("normal! G")
      end)
    end
  end
end, 200)

vim.defer_fn(function()
  hide_chrome()
  unshadow_triggers()
  scrub_win(thread_win())
  M.rail_scrub()
  apply_view()
end, 1500)

return M
