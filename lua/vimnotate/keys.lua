local M = require("vimnotate")
local core = require("vimnotate.core")
local ops = require("vimnotate.ops")
local thread = core.thread
local operator = ops.operator
local line_motion = ops.line_motion

local K = {}

local repeatable_jump = nil
local function jump_key(dir)
  return function()
    if repeatable_jump == nil then
      repeatable_jump = false
      local ok, rm = pcall(require, "nvim-treesitter-textobjects.repeatable_move")
      if ok and type(rm) == "table" and type(rm.make_repeatable_move) == "function" then
        repeatable_jump = rm.make_repeatable_move(function(opts)
          M.jump(opts.forward and 1 or -1, vim.v.count1)
        end)
      end
    end
    if repeatable_jump then
      repeatable_jump({ forward = dir > 0 })
    else
      M.jump(dir, vim.v.count1)
    end
  end
end

function K.setup()
  local bo = { buffer = thread, nowait = true }
  local ebo = { buffer = thread, nowait = true, expr = true }
  local keys = core.keys
  for _, kind in ipairs(core.OP_KINDS) do
    local key = keys[kind]
    vim.keymap.set("n", key, operator(kind), ebo)
    vim.keymap.set("x", "<Plug>(vimnotate-" .. kind .. ")", operator(kind), ebo)
    if not core.textobj_prefix(key) then
      vim.keymap.set("x", key, operator(kind), ebo)
      vim.keymap.set("o", key, line_motion(kind, key), ebo)
    end
  end
  if keys.comment ~= "w" then
    vim.keymap.set("n", keys.comment .. "w", operator("comment", "w"), ebo)
  end
  local upper = core.upper_comment_key()
  if upper then
    vim.keymap.set("n", upper, operator("comment", "_"), ebo)
    if not core.textobj_prefix(keys.comment) then
      vim.keymap.set("x", upper, operator("comment"), ebo)
    end
  end
  vim.keymap.set("n", "]a", jump_key(1), bo)
  vim.keymap.set("n", "[a", jump_key(-1), bo)
  vim.keymap.set("n", "K", M.hover, bo)
  vim.keymap.set("n", "u", function()
    M.undo()
  end, bo)
  vim.keymap.set("n", "<C-r>", function()
    M.redo()
  end, bo)
  vim.keymap.set("n", "<C-o>", function()
    M.jumplist(-1, vim.v.count1)
  end, bo)
  vim.keymap.set("n", "<C-i>", function()
    M.jumplist(1, vim.v.count1)
  end, bo)
  for _, lhs in ipairs(M.BUFFER_SWITCHERS) do
    vim.keymap.set("n", lhs, "<Nop>", bo)
  end
  vim.keymap.set("n", "e", M.edit, bo)
  vim.keymap.set("n", "x", M.remove_at_cursor, bo)
  vim.keymap.set("n", "q", "<Cmd>qa<CR>", bo)
  vim.keymap.set("n", "<Tab>", M.note_toggle, bo)
  vim.keymap.set("n", "<S-Tab>", M.rail_focus, bo)
  vim.keymap.set("n", "R", M.cycle_view, bo)
  vim.keymap.set("n", "H", "H", bo)
  vim.keymap.set("n", "L", "L", bo)
  vim.keymap.set("n", "<ScrollWheelDown>", M.wheel("<ScrollWheelDown>", 3), ebo)
  vim.keymap.set("n", "<ScrollWheelUp>", M.wheel("<ScrollWheelUp>", -3), ebo)
end

return K
