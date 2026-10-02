local V = require("vimnotate")
local A = V.annotations
local T = { lines = {}, name = "?" }
_G.T = T

local function out(line)
  T.lines[#T.lines + 1] = line
end

function T.ok(cond, label)
  out((cond and "ok " or "FAIL ") .. T.name .. ": " .. label)
  return cond
end

function T.eq(got, want, label)
  if vim.deep_equal(got, want) then
    return T.ok(true, label)
  end
  out("FAIL " .. T.name .. ": " .. label .. "\n  got:  " .. vim.inspect(got) .. "\n  want: " .. vim.inspect(want))
  return false
end

function T.row(pat, nth)
  local n = 0
  for i, l in ipairs(vim.api.nvim_buf_get_lines(V.thread, 0, -1, false)) do
    local s = l:find(pat, 1, true)
    if s then
      n = n + 1
      if n == (nth or 1) then
        return i - 1, s - 1
      end
    end
  end
  error("not in thread: " .. pat)
end

function T.add(row, kind, body, sent)
  return A.add({ srow = row, scol = 0, erow = row, ecol = 0, linewise = true, kind = kind, body = body or "", sent = sent })
end

function T.addchar(row, scol, ecol, kind, body)
  return A.add({ srow = row, scol = scol, erow = row, ecol = ecol, linewise = false, kind = kind, body = body or "" })
end

function T.items()
  local res = {}
  for _, it in ipairs(A.list()) do
    local r = A.range(it)
    res[#res + 1] = {
      kind = it.kind,
      body = it.body,
      sent = it.sent or false,
      lw = it.linewise,
      at = r.linewise and { r.srow, r.erow } or { r.srow, r.scol, r.erow, r.ecol },
    }
  end
  return res
end

function T.cursor(row, col)
  vim.api.nvim_set_current_win(V.thread_win())
  vim.api.nvim_win_set_cursor(0, { row + 1, col or 0 })
end

function T.keys(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

function T.step()
  V.history.step = nil
end

function T.finish(cmd)
  out("END " .. T.name)
  local f = assert(io.open(vim.env.VIMNOTATE_TEST_OUT, "a"))
  f:write(table.concat(T.lines, "\n"), "\n")
  f:close()
  vim.cmd(cmd or "Send")
end

function T.run(file, name)
  T.name = name
  vim.schedule(function()
    local ok, err = pcall(function()
      dofile(file)[name](V, A)
    end)
    if not ok then
      out("FAIL " .. name .. ": error: " .. tostring(err))
      T.finish("qa!")
    end
  end)
end

return T
