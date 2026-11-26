--- Registration of this nvim in the rex-nvim registry.
---
--- Every nvim running in a Rex pane writes <state>/<pid>.reg with four lines:
--- the physical working directory (its "project root"), $REX_SESSION,
--- $REX_BLOCK and v:servername. `rex-nvim open` (lib/registry.zsh) reads
--- these files to route clicked files to the right nvim. The file is written
--- atomically (temp file + rename) only once the RPC server exists, so a
--- reader never sees a registration it cannot reach. A Unix socket whose file
--- was deleted (a cleanup of $TMPDIR) is reopened on the next write.
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

--- The RPC address to register, reopening the socket when its file is gone.
---
--- nvim keeps a deleted socket in `v:servername`, but nobody can connect to it
--- any more, so stopping it costs nothing. The same path is tried first, so a
--- `--listen` address or another tool holding it keeps working; a fresh
--- address is the fallback when its directory is gone too. The value returned
--- by `serverstart()` is what gets registered: with other listeners open,
--- `v:servername` moves to one of those instead. TCP addresses (no leading
--- "/") have no file to check and are left alone.
--- @return string|nil address, or nil when no server could be started
local function live_server()
  local server = vim.v.servername
  if server == nil or server == "" then
    return vim.fn.serverstart()
  end
  if server:sub(1, 1) ~= "/" or vim.uv.fs_stat(server) then
    return server
  end
  pcall(vim.fn.serverstop, server)
  local dir = vim.uv.fs_stat(vim.fs.dirname(server))
  if dir and dir.type == "directory" then
    local ok, addr = pcall(vim.fn.serverstart, server)
    if ok and addr ~= "" then
      return addr
    end
  end
  local ok, addr = pcall(vim.fn.serverstart)
  if ok and addr ~= "" then
    return addr
  end
  vim.notify("rex-nvim: RPC socket " .. server .. " is gone and could not be reopened: " .. tostring(addr), vim.log.levels.WARN)
  return nil
end

--- Write or refresh this nvim's registration. Called on startup, on a global
--- directory change and when the pane gains focus (its mtime then marks the
--- most recently used nvim, which wins when several share a root).
function M.write()
  local server = live_server()
  if not server then
    return
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
