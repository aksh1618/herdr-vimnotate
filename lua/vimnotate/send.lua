local M = require("vimnotate")
local core = require("vimnotate.core")
local store = require("vimnotate.store")
local Co = require("vimnotate.compose")
local restore = require("vimnotate.restore")
local A = store.A
local warn = core.warn
local reply_path = core.reply_path
local note_text = core.note_text
local save_state = restore.save_state

local Sd = {}
local cancelled = false

local function quote_lines(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = ("> " .. l):gsub("%s+$", "")
  end
  return table.concat(out, "\n")
end

local function reply_text(body)
  return (body:gsub("^(%s*)>", "%1\\>"):gsub("\n(%s*)>", "\n%1\\>"))
end

function M.export()
  local parts = {}
  local note = note_text()
  if note ~= "" then
    parts[#parts + 1] = note
  end
  local items = vim.tbl_filter(function(item)
    return not item.sent
  end, A.list())
  for _, item in ipairs(items) do
    local body = reply_text(vim.trim(item.body))
    local reply = body
    if item.kind == "delete" then
      reply = body == "" and "Remove this." or body:find("\n") and ("Remove this.\n" .. body) or ("Remove this. " .. body)
    elseif item.kind == "good" then
      reply = body == "" and "Looks good." or ("Looks good.\n" .. body)
    end
    local block = quote_lines(A.text(item))
    if reply ~= "" then
      block = block .. "\n\n" .. reply
    end
    parts[#parts + 1] = block
  end
  return table.concat(parts, "\n\n")
end

local function flush()
  if cancelled then
    return
  end
  if M.composing() then
    Co.finish(true)
  end
  local text = M.export()
  if text == "" then
    os.remove(reply_path)
  else
    local out = assert(io.open(reply_path, "wb"))
    out:write(text, "\n")
    out:close()
  end
  local ok, err = pcall(save_state)
  if not ok then
    warn("vimnotate state: " .. tostring(err))
  end
end

function Sd.setup()
  vim.api.nvim_create_autocmd("VimLeavePre", { callback = flush })
  vim.api.nvim_create_user_command("Cancel", function()
    cancelled = true
    os.remove(reply_path)
    vim.cmd("qa!")
  end, { range = true })
  vim.api.nvim_create_user_command("Send", function()
    flush()
    cancelled = true
    vim.cmd("qa!")
  end, { range = true })
end

return Sd
