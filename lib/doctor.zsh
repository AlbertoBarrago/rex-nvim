# rex-nvim doctor: check the whole chain a click goes through and say what is
# wrong. Bindings are checked by asking macOS which app would open a file of
# each type, never by trusting duti (it reports success while the
# confirmation dialog is still pending, or after the user picked another app).

source $REX_NVIM_ROOT/lib/types.zsh
source $REX_NVIM_ROOT/lib/config.zsh

integer doctor_failures=0
ok()   { print -r -- "  ok    $1" }
warn() { print -r -- "  warn  $1" }
fail() { print -r -- "  FAIL  $1"; (( doctor_failures++ )) }

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

rex_nvim_doctor() {
  local tool bin app_bin ext got probe
  local -a wrong kept_elsewhere kept

  print "tools"
  for tool in nvim jq perl duti rex; do
    if command -v $tool >/dev/null; then ok $tool; else fail "$tool not found"; fi
  done
  command -v glow >/dev/null && ok glow || warn "glow not found: Markdown opens in nvim"

  print "NvimOpen.app"
  if [[ ! -d $REX_NVIM_APP ]]; then
    fail "$REX_NVIM_APP missing: run rex-nvim install"
  else
    app_bin=$(plutil -extract RexNvimBin raw -o - $REX_NVIM_APP/Contents/Info.plist 2>/dev/null)
    bin=$REX_NVIM_ROOT/bin/rex-nvim
    if [[ -z $app_bin ]]; then
      warn "app built by an older install: run rex-nvim install"
    elif [[ ! -x $app_bin ]]; then
      fail "app calls $app_bin, which is gone: run rex-nvim install"
    elif [[ ${app_bin:A} != ${bin:A} ]]; then
      warn "app calls $app_bin, not this clone"
    else
      ok "calls $app_bin"
    fi
  fi

  print "file types"
  rex_nvim_keep_read
  kept=($reply)
  integer bound=$(( ${#REX_NVIM_TYPES} - ${#kept} ))
  probe=$(mktemp -d) || return 1
  for ext in ${(ko)REX_NVIM_TYPES}; do
    : > $probe/probe.$ext
    got=$(default_app $probe/probe.$ext)
    if (( ${kept[(Ie)$ext]} )); then
      kept_elsewhere+=("$ext -> ${${got:t:r}:-none}")
    elif [[ $got != $REX_NVIM_APP ]]; then
      wrong+=("$ext -> ${${got:t:r}:-none}")
    fi
  done
  rm -rf $probe
  if (( ${#wrong} )); then
    fail "${#wrong} of $bound types open elsewhere: ${(j:, :)wrong}"
    print -r -- "        bind them with: rex-nvim install ${(j: :)${wrong%% *}}"
  else
    ok "all $bound types open with NvimOpen"
  fi
  (( ${#kept_elsewhere} )) && ok "kept on purpose: ${(j:, :)kept_elsewhere} (see $REX_NVIM_KEEP_FILE)"

  print "browser"
  for probe in https://example.com http://example.com; do
    got=$(default_app $probe)
    if [[ $got == $REX_NVIM_APP ]]; then fail "${probe%%:*} links open with NvimOpen"; else ok "${probe%%:*} -> ${got:t:r}"; fi
  done
  probe=$(mktemp -d)
  : > $probe/probe.html
  got=$(default_app $probe/probe.html)
  rm -rf $probe
  if [[ $got == $REX_NVIM_APP ]]; then fail ".html opens with NvimOpen"; else ok "html -> ${got:t:r}"; fi

  print "Rex"
  if [[ -n $(rex_app_client) ]]; then ok "Rex app connected"; else warn "Rex app not connected"; fi
  # The config is what decides; running instances are only informative (none
  # is open most of the time a doctor runs).
  case $(plugin_loaded) in
    yes) ok "nvim config loads the rex-nvim plugin" ;;
    no)  fail "nvim config does not load the rex-nvim plugin (see README, Install)" ;;
    *)   warn "could not ask nvim whether its config loads the plugin (no answer in 15s)" ;;
  esac
  local reg
  integer live=0
  for reg in ${(f)"$(rex_nvim_live_regs)"}; do
    rex_nvim_read_reg $reg || continue
    (( live++ ))
    ok "nvim ${reg:t:r} on ${reply[1]/#$HOME/~}"
  done
  (( live )) || print -r -- "  info  no nvim open in a Rex pane right now"

  print
  if (( doctor_failures )); then
    print "$doctor_failures problem(s) found"
    return 1
  fi
  print "all good"
}
