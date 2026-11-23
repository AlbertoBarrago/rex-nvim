-- rex-nvim: register this nvim so files clicked in Rex open here.
-- Only nvim running inside a Rex pane ($REX_BLOCK set) registers.
if vim.g.loaded_rex_nvim then
  return
end
vim.g.loaded_rex_nvim = true

if vim.env.REX_BLOCK == nil or vim.env.REX_BLOCK == "" then
  return
end

local registry = require("rex-nvim.registry")
local group = vim.api.nvim_create_augroup("rex-nvim", { clear = true })

vim.api.nvim_create_autocmd("DirChanged", { group = group, pattern = "global", callback = registry.write })
vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = registry.write })
vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = registry.remove })

-- Plugin managers may load this after startup; register right away then.
if vim.v.vim_did_enter == 1 then
  registry.write()
else
  vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = registry.write })
end
