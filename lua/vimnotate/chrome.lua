local M = require("vimnotate")
local core = require("vimnotate.core")
local store = require("vimnotate.store")
local A = store.A
local thread = core.thread
local thread_win = core.thread_win
local KINDS = core.KINDS
local view = core.view
local reply_path = core.reply_path
local note_text = core.note_text

local Ch = { markdown_warm = false }

local function refresh_loclist()
  local tw = thread_win()
  if tw == -1 then
    return
  end
  local items = {}
  for _, item in ipairs(A.list()) do
    local r = A.range(item)
    items[#items + 1] = {
      bufnr = thread,
      lnum = r.srow + 1,
      col = r.linewise and 1 or r.scol + 1,
      end_lnum = r.erow + 1,
      end_col = r.linewise and 0 or r.ecol + 1,
      text = A.describe(item),
    }
  end
  vim.fn.setloclist(tw, {}, "r", { title = "vimnotate annotations", items = items })
end

local HINTS = "c d p {motion} comment/delete/good · u undo · ]a [a · K show · e edit · x remove · R toggle view · Tab note · q send"

local function thread_winbar()
  local counts, sent = {}, 0
  for _, item in pairs(A.items) do
    if item.sent then
      sent = sent + 1
    else
      counts[item.kind] = (counts[item.kind] or 0) + 1
    end
  end
  local tally = {}
  for _, k in ipairs({ "comment", "delete", "good" }) do
    if counts[k] then
      tally[#tally + 1] = KINDS[k].glyph .. counts[k]
    end
  end
  if sent > 0 then
    tally[#tally + 1] = sent .. " sent"
  end
  if note_text() ~= "" then
    tally[#tally + 1] = "%@v:lua.vimnotate_note_click@%#VimnotateWinbarNote#✎ note%*%T"
  end
  local head = "%#VimnotateMode# VIMNOTATE %*"
  if #tally > 0 then
    head = head .. " " .. table.concat(tally, " ")
  end
  if view.flash then
    head = head .. " · " .. view.flash
  end
  return head .. " · %<" .. HINTS
end

local function refresh_winbar()
  local tw = thread_win()
  if tw ~= -1 then
    vim.wo[tw].winbar = thread_winbar()
  end
end

local function hide_chrome()
  vim.o.mouse = "a"
  for _, lhs in ipairs({ "<LeftMouse>", "<LeftDrag>", "<LeftRelease>", "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>" }) do
    pcall(vim.keymap.del, { "n", "i", "v", "x" }, lhs)
  end
  pcall(function()
    require("lualine").hide()
  end)
  vim.o.laststatus = 0
end

local function prewarm_markdown()
  if Ch.markdown_warm then
    return
  end
  Ch.markdown_warm = true
  local buf = vim.fn.bufadd(vim.fn.fnamemodify(reply_path, ":h") .. "/.warmup.md")
  vim.fn.bufload(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.bo[buf].filetype = "markdown"
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
end

local function unshadow(maps, mode, lhs)
  local prefix = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  local umbrella = mode == "x" and "v" or mode
  for _, m in ipairs(maps) do
    local applies = m.buffer == 0
      and (m.mode == " " or m.mode:find(mode, 1, true) or m.mode:find(umbrella, 1, true))
    if applies then
      local other = m.lhsraw or vim.api.nvim_replace_termcodes(m.lhs, true, false, true)
      if #other > #prefix and other:sub(1, #prefix) == prefix then
        pcall(vim.keymap.del, mode, m.lhs)
      end
    end
  end
end

M.BUFFER_SWITCHERS = { "]b", "[b", "]B", "[B", "]A", "[A", "<Space><Space>", "<C-^>", "<C-6>", "gf", "gF" }

local TRIGGERS = {
  n = { "c", "C", "d", "p", "x", "e", "K", "u", "<C-r>", "<C-o>", "<C-i>", "]a", "[a", "q", "R", "H", "L", "<Tab>", "<S-Tab>", "<LeftMouse>" },
  x = { "c", "C", "d", "p", "<LeftMouse>" },
  o = { "c", "d", "p" },
}
M.TRIGGERS = TRIGGERS

local function unshadow_triggers()
  local maps = vim.fn.maplist()
  for mode, keys in pairs(TRIGGERS) do
    for _, lhs in ipairs(keys) do
      unshadow(maps, mode, lhs)
    end
  end
end
M.unshadow_triggers = unshadow_triggers
local unshadow_queued = false

function Ch.setup()
  A.on_change(function()
    refresh_loclist()
    refresh_winbar()
  end)

  vim.api.nvim_create_autocmd("OptionSet", {
    pattern = "laststatus",
    callback = function()
      if vim.o.laststatus ~= 0 then
        vim.schedule(function()
          vim.o.laststatus = 0
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    pattern = "LazyLoad",
    callback = function()
      if unshadow_queued then
        return
      end
      unshadow_queued = true
      vim.schedule(function()
        unshadow_queued = false
        unshadow_triggers()
      end)
    end,
  })
end

Ch.thread_winbar = thread_winbar
Ch.refresh_winbar = refresh_winbar
Ch.hide_chrome = hide_chrome
Ch.prewarm_markdown = prewarm_markdown
Ch.unshadow_triggers = unshadow_triggers

return Ch
