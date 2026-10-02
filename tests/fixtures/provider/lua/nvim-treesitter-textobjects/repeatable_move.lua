local M = { last_move = nil }

function M.make_repeatable_move(fn)
  return function(opts, ...)
    M.last_move = { func = fn, opts = vim.deepcopy(opts), args = { ... } }
    fn(opts, ...)
  end
end

local function repeat_move(forward)
  local last = M.last_move
  if not last then
    return
  end
  if type(last.func) == "string" then
    local same = (last.func == "f" or last.func == "t") == forward
    vim.cmd("normal! " .. vim.v.count1 .. (same and ";" or ","))
    return
  end
  last.func(vim.tbl_extend("force", last.opts, { forward = forward }), unpack(last.args))
end

function M.repeat_last_move_next()
  repeat_move(true)
end

function M.repeat_last_move_previous()
  repeat_move(false)
end

function M.builtin_f_expr()
  M.last_move = { func = "f", opts = { forward = true }, args = {} }
  return "f"
end

return M
