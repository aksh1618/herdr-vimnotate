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
  vim.keymap.set("n", "c", operator("comment"), ebo)
  vim.keymap.set("n", "d", operator("delete"), ebo)
  vim.keymap.set("n", "p", operator("good"), ebo)
  vim.keymap.set("n", "cw", operator("comment", "w"), ebo)
  vim.keymap.set("n", "C", operator("comment", "_"), ebo)
  vim.keymap.set("x", "c", operator("comment"), ebo)
  vim.keymap.set("x", "C", operator("comment"), ebo)
  vim.keymap.set("x", "d", operator("delete"), ebo)
  vim.keymap.set("x", "p", operator("good"), ebo)
  vim.keymap.set("o", "c", line_motion("comment", "c"), ebo)
  vim.keymap.set("o", "d", line_motion("delete", "d"), ebo)
  vim.keymap.set("o", "p", line_motion("good", "p"), ebo)
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
