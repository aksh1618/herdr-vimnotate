local M = require("vimnotate")
local core = require("vimnotate.core")
local store = require("vimnotate.store")
local chrome = require("vimnotate.chrome")
local A = store.A
local thread = core.thread
local thread_win = core.thread_win
local KINDS = core.KINDS
local view = core.view
local line_len = core.line_len
local unshadow_triggers = chrome.unshadow_triggers

local Co = {}

local pending_ns = vim.api.nvim_create_namespace("vimnotate.pending")
local COMPOSE_MIN_WIDTH = 48
local COMPOSE_MAX_ROWS = 8
local compose = nil

local function compose_title(c, insert)
  local verb = (c.item and c.item.kind == c.kind) and "edit" or "comment"
  if insert == nil then
    insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  end
  if insert then
    return " " .. verb .. " · enter saves · ctrl-j new line · esc normal "
  end
  return " " .. verb .. " · enter saves · q cancels · i insert "
end

local function compose_body(c)
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(c.buf, 0, -1, false), "\n"))
end

function M.composing()
  return compose
end

local function compose_resize(c)
  if not vim.api.nvim_win_is_valid(c.win) then
    return
  end
  local h = vim.api.nvim_win_text_height(c.win, {}).all
  c.height = math.max(1, math.min(h, COMPOSE_MAX_ROWS))
  local cfg = M.compose_layout(c)
  cfg.title = compose_title(c)
  cfg.title_pos = "left"
  if not vim.deep_equal(cfg, c.cfg) then
    c.cfg = cfg
    vim.api.nvim_win_set_config(c.win, cfg)
  end
end

local function compose_finish(save)
  local c = compose
  if not c then
    return
  end
  compose = nil
  vim.api.nvim_buf_clear_namespace(thread, pending_ns, 0, -1)
  local body = vim.api.nvim_buf_is_valid(c.buf) and compose_body(c) or ""
  if save then
    if c.item then
      if A.items[c.item.id] then
        if c.kind ~= c.item.kind then
          if body ~= "" or c.kind ~= "comment" then
            A.update(c.item.id, { body = body, kind = c.kind })
          end
        elseif body == "" and c.kind == "comment" then
          A.remove(c.item.id)
        else
          A.update(c.item.id, { body = body })
        end
      end
    elseif body ~= "" then
      local spec = vim.deepcopy(c.range)
      spec.kind = "comment"
      spec.body = body
      A.add(spec)
      M.last_body = body
    end
  end
  M.apply_view()
  if vim.api.nvim_win_is_valid(c.win) then
    vim.api.nvim_win_close(c.win, true)
  end
  local tw = thread_win()
  if tw ~= -1 then
    vim.api.nvim_set_current_win(tw)
    M.restore_repeat()
  end
  unshadow_triggers()
end

function M.compose_save()
  compose_finish(true)
end

function M.compose_cancel()
  compose_finish(false)
end

function M.compose(opts)
  if compose then
    compose_finish(true)
  end
  M.bars_hide()
  local item = opts.item
  local r = item and A.range(item) or opts.range
  local c = { item = item, range = r, height = 1, kind = opts.kind or (item and item.kind) or "comment" }
  local accent = KINDS[c.kind]
  c.inline = (item and view.mode or M.planned(thread_win())) == "inline"
  local whole = r.linewise and r.erow + 1 < vim.api.nvim_buf_line_count(thread)
  vim.api.nvim_buf_set_extmark(thread, pending_ns, r.srow, r.linewise and 0 or r.scol, {
    end_row = whole and r.erow + 1 or r.erow,
    end_col = whole and 0 or (r.linewise and line_len(r.erow) or r.ecol),
    hl_group = accent.hl .. "Active",
    hl_eol = r.linewise or nil,
    priority = 4300,
  })
  c.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[c.buf].bufhidden = "wipe"
  local body = opts.body or (item and item.body) or ""
  vim.api.nvim_buf_set_lines(c.buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
  compose = c
  local title = compose_title(c, true)
  c.base_width = math.max(COMPOSE_MIN_WIDTH, vim.fn.strdisplaywidth(title) + 2, vim.fn.strdisplaywidth(compose_title(c, false)) + 2)
  local cfg = M.compose_layout(c)
  cfg.border = "rounded"
  cfg.style = "minimal"
  cfg.title = title
  cfg.title_pos = "left"
  c.win = vim.api.nvim_open_win(c.buf, true, cfg)
  vim.wo[c.win].conceallevel = 2
  chrome.markdown_warm = true
  vim.bo[c.buf].filetype = "markdown"
  vim.wo[c.win].wrap = true
  vim.wo[c.win].linebreak = c.inline
  vim.wo[c.win].winfixbuf = false
  vim.wo[c.win].winhighlight = "FloatBorder:" .. accent.hl .. "Border,FloatTitle:VimnotateTitle"
  local o = { buffer = c.buf, nowait = true }
  vim.keymap.set("i", "<CR>", "<Esc><Cmd>lua require('vimnotate').compose_save()<CR>", o)
  vim.keymap.set("i", "<C-j>", "<CR>", o)
  vim.keymap.set("i", "<S-CR>", "<CR>", o)
  vim.keymap.set("i", "<M-CR>", "<CR>", o)
  vim.keymap.set("n", "<CR>", M.compose_save, o)
  vim.keymap.set("n", "q", M.compose_cancel, o)
  local group = vim.api.nvim_create_augroup("vimnotate.compose", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "WinResized" }, {
    group = group,
    callback = function()
      if compose == c then
        compose_resize(c)
      end
    end,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      if compose == c and vim.api.nvim_win_is_valid(c.win) then
        vim.api.nvim_win_set_config(c.win, { title = compose_title(c), title_pos = "left" })
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufWipeout" }, {
    group = group,
    buffer = c.buf,
    callback = function()
      vim.schedule(function()
        if compose == c then
          compose_finish(true)
        end
      end)
    end,
  })
  local last = vim.api.nvim_buf_line_count(c.buf)
  vim.api.nvim_win_set_cursor(c.win, { last, 0 })
  compose_resize(c)
  vim.cmd("startinsert!")
  return c
end

Co.finish = compose_finish

return Co
