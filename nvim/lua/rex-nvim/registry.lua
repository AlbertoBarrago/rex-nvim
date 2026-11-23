--- Registration of this nvim in the rex-nvim registry.
---
--- Every nvim running in a Rex pane writes <state>/<pid>.reg with four lines:
--- the physical working directory (its "project root"), $REX_SESSION,
--- $REX_BLOCK and v:servername. `rex-nvim open` (lib/registry.zsh) reads
--- these files to route clicked files to the right nvim. The file is written
--- atomically (temp file + rename) only once the RPC server exists, so a
--- reader never sees a registration it cannot reach.
local M = {}

--- @return string
local function state_dir()
  local dir = vim.env.REX_NVIM_STATE_DIR
  if dir == nil or dir == "" then
    dir = vim.fn.expand("~/.cache/rex-nvim")
  end
  return dir
end

--- @return string
local function reg_path()
  return state_dir() .. "/" .. vim.fn.getpid() .. ".reg"
end

--- Write or refresh this nvim's registration. Called on startup, on a global
--- directory change and when the pane gains focus (its mtime then marks the
--- most recently used nvim, which wins when several share a root).
function M.write()
  local server = vim.v.servername
  if server == nil or server == "" then
    server = vim.fn.serverstart()
  end
  local cwd = vim.fn.getcwd(-1, -1)
  local root = vim.uv.fs_realpath(cwd) or cwd
  local dir = state_dir()
  vim.fn.mkdir(dir, "p")
  local path = reg_path()
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then
    vim.notify("rex-nvim: cannot register: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  f:write(table.concat({ root, vim.env.REX_SESSION or "", vim.env.REX_BLOCK, server }, "\n"), "\n")
  f:close()
  local ok, rename_err = os.rename(tmp, path)
  if not ok then
    vim.notify("rex-nvim: cannot register: " .. tostring(rename_err), vim.log.levels.WARN)
  end
end

--- Remove this nvim's registration (on exit).
function M.remove()
  os.remove(reg_path())
end

return M
