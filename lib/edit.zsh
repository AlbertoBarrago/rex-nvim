# rex-nvim edit [DIR]: start nvim in DIR with the rex-nvim plugin loaded.
#
# Registration is done by the plugin itself, so any nvim with the plugin in
# its config is reachable; `edit` only makes sure the plugin is loaded when
# the user's config does not list it (a second load is a no-op).

rex_nvim_edit() {
  local dir=${1:-.}
  builtin cd -- $dir || return
  command -v nvim >/dev/null || { notify "nvim not found in PATH"; return 69 }
  exec nvim -c "lua vim.opt.rtp:append([==[$REX_NVIM_ROOT/nvim]==]); vim.cmd.runtime('plugin/rex-nvim.lua')" .
}
