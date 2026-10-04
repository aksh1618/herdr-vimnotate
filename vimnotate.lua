local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/lua/vimnotate/"
for file in vim.fs.dir(dir) do
  local mod = file:match("^(.+)%.lua$")
  if mod then
    local name = mod == "init" and "vimnotate" or "vimnotate." .. mod
    package.loaded[name] = nil
    package.preload[name] = function()
      return dofile(dir .. file)
    end
  end
end
require("vimnotate")
