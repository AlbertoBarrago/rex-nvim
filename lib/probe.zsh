# Read-only questions to the system, shared by lib/doctor.zsh and
# lib/wizard.zsh. Tests redefine these functions after sourcing.

# default_app TARGET: print the path of the app macOS would open TARGET with
# (a file path, or a URL when it contains "://").
default_app() {
  local js
  if [[ $1 == *://* ]]; then
    js='ObjC.import("AppKit"); function run(a) { var u = $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL($.NSURL.URLWithString(a[0])); return u.isNil() ? "" : u.path.js }'
  else
    js='ObjC.import("AppKit"); function run(a) { var u = $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL($.NSURL.fileURLWithPath(a[0])); return u.isNil() ? "" : u.path.js }'
  fi
  osascript -l JavaScript -e $js -- $1 2>/dev/null
}

# plugin_loaded: whether the user's nvim config loads the rex-nvim plugin,
# asked of a headless nvim. Prints yes, no, or nothing when nvim did not
# answer in time (a config that hangs headless).
plugin_loaded() {
  local out
  out=$(with_timeout 15 nvim --headless \
    -c 'lua io.stdout:write(vim.g.loaded_rex_nvim and "\nREX_NVIM_PLUGIN=yes\n" or "\nREX_NVIM_PLUGIN=no\n")' \
    -c 'qa!' </dev/null 2>/dev/null)
  [[ $out == *REX_NVIM_PLUGIN=yes* ]] && { print yes; return }
  [[ $out == *REX_NVIM_PLUGIN=no* ]] && print no
}
