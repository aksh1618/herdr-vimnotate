local Hl = {}

local owned = {}

local function own(name, spec)
  local cur = vim.api.nvim_get_hl(0, { name = name })
  if next(cur) == nil or vim.deep_equal(cur, owned[name]) then
    vim.api.nvim_set_hl(0, name, spec)
    owned[name] = vim.api.nvim_get_hl(0, { name = name })
  end
end

local function define_highlights()
  vim.api.nvim_set_hl(0, "VimnotateComment", { bg = "#5f5f00", ctermbg = 58 })
  vim.api.nvim_set_hl(0, "VimnotateGood", { bg = "#005f00", ctermbg = 22 })
  vim.api.nvim_set_hl(0, "VimnotateDelete", { bg = "#5f0000", ctermbg = 52, strikethrough = true, cterm = { strikethrough = true } })
  vim.api.nvim_set_hl(0, "VimnotateCommentMark", { fg = "#afaf5f", ctermfg = 143, italic = true, cterm = { italic = true } })
  vim.api.nvim_set_hl(0, "VimnotateGoodMark", { fg = "#5faf5f", ctermfg = 71, italic = true, cterm = { italic = true } })
  vim.api.nvim_set_hl(0, "VimnotateDeleteMark", { fg = "#d75f5f", ctermfg = 167, italic = true, cterm = { italic = true } })
  vim.api.nvim_set_hl(0, "VimnotateCommentBorder", { fg = "#d7d700", ctermfg = 184 })
  vim.api.nvim_set_hl(0, "VimnotateGoodBorder", { fg = "#5fd75f", ctermfg = 77 })
  vim.api.nvim_set_hl(0, "VimnotateDeleteBorder", { fg = "#ff5f5f", ctermfg = 203 })
  vim.api.nvim_set_hl(0, "VimnotateTitle", { link = "Comment" })
  vim.api.nvim_set_hl(0, "VimnotateBar", { fg = "#d0d0d0", bg = "#444444", ctermfg = 252, ctermbg = 238 })
  for _, name in ipairs({ "Comment", "Good", "Delete" }) do
    local accent = vim.api.nvim_get_hl(0, { name = "Vimnotate" .. name .. "Border" })
    vim.api.nvim_set_hl(0, "VimnotateBar" .. name, { fg = accent.fg, ctermfg = accent.ctermfg, bg = "#444444", ctermbg = 238, bold = true, cterm = { bold = true } })
    vim.api.nvim_set_hl(0, "Vimnotate" .. name .. "BorderBold", { fg = accent.fg, ctermfg = accent.ctermfg, bold = true, cterm = { bold = true } })
  end
  vim.api.nvim_set_hl(0, "VimnotateCommentActive", { bg = "#878700", ctermbg = 100 })
  vim.api.nvim_set_hl(0, "VimnotateGoodActive", { bg = "#008700", ctermbg = 28 })
  vim.api.nvim_set_hl(0, "VimnotateDeleteActive", { bg = "#870000", ctermbg = 88, strikethrough = true, cterm = { strikethrough = true } })
  vim.api.nvim_set_hl(0, "VimnotateCommentSent", { bg = "#3a3a1c", ctermbg = 237 })
  vim.api.nvim_set_hl(0, "VimnotateGoodSent", { bg = "#1c3a1c", ctermbg = 237 })
  vim.api.nvim_set_hl(0, "VimnotateDeleteSent", { bg = "#3a1c1c", ctermbg = 237, strikethrough = true, cterm = { strikethrough = true } })
  vim.api.nvim_set_hl(0, "VimnotateSentMark", { fg = "#6c6c6c", ctermfg = 242, italic = true, cterm = { italic = true } })
  for name, dim in pairs({ Comment = { "#87875f", 101 }, Good = { "#5f875f", 65 }, Delete = { "#875f5f", 95 } }) do
    vim.api.nvim_set_hl(0, "Vimnotate" .. name .. "BorderSent", { fg = dim[1], ctermfg = dim[2] })
    vim.api.nvim_set_hl(0, "Vimnotate" .. name .. "BorderSentBold", { fg = dim[1], ctermfg = dim[2], bold = true, cterm = { bold = true } })
  end
  vim.api.nvim_set_hl(0, "VimnotateEdge", { fg = "#626262", ctermfg = 241 })
  vim.api.nvim_set_hl(0, "VimnotateLabel", { fg = "#8a8a8a", ctermfg = 245, italic = true, cterm = { italic = true } })
  local light = vim.o.background == "light"
  vim.api.nvim_set_hl(0, "VimnotateWinbarNote", { fg = light and "#5f5f00" or "#d7d700", ctermfg = light and 58 or 184, bold = true, cterm = { bold = true } })
  own("VimnotateMode", { fg = "#1c1c1c", bg = "#ffc340", ctermfg = 234, ctermbg = 214, bold = true, cterm = { bold = true } })
  own("VimnotateWinbar", light
    and { fg = "#4a3c1e", bg = "#f2e6c9", ctermfg = 237, ctermbg = 223 }
    or { fg = "#d6cbb0", bg = "#2b2620", ctermfg = 251, ctermbg = 235 })
  own("VimnotateMsgArea", { link = "VimnotateWinbar" })
  vim.api.nvim_set_hl(0, "MsgArea", { link = "VimnotateMsgArea" })
end

function Hl.setup()
  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })
  vim.api.nvim_create_autocmd("OptionSet", { pattern = "background", callback = define_highlights })
end

Hl.define_highlights = define_highlights

return Hl
