# rex-nvim doctor: check the whole chain a click goes through and say what is
# wrong. Bindings are checked by asking macOS which app would open a file of
# each type, never by trusting duti (it reports success while the
# confirmation dialog is still pending, or after the user picked another app).

source $REX_NVIM_ROOT/lib/types.zsh
source $REX_NVIM_ROOT/lib/config.zsh
source $REX_NVIM_ROOT/lib/probe.zsh
source $REX_NVIM_ROOT/lib/ui.zsh

integer doctor_failures=0
ok()   { ui_status ok "$1" }
warn() { ui_status warn "$1" }
fail() { ui_status fail "$1"; (( doctor_failures++ )) }

# rex_nvim_doctor_rex_scope: the file types check in the rex scope, where
# none should open with NvimOpen. Leftovers of a global install only warn:
# files still open, just outside the scope chosen.
rex_nvim_doctor_rex_scope() {
  local ext probe link
  local -a on
  integer probed=0
  # The whole point of the scope: the app must be what macOS opens these
  # links with (a missing or unregistered app passes the bundle check above).
  link=$(default_app rex-nvim://open/tmp/probe)
  if [[ $link == $REX_NVIM_APP ]]; then
    ok "rex-nvim:// links open with NvimOpen"
  else
    fail "rex-nvim:// links open with ${${link:t:r}:-nothing}: run rex-nvim install"
  fi
  probe=$(mktemp -d) || return 1
  for ext in ${(ko)REX_NVIM_TYPES}; do
    : > $probe/probe.$ext
    [[ $(default_app $probe/probe.$ext) == $REX_NVIM_APP ]] && on+=($ext)
    ui_progress "asking macOS which app opens each type" $(( ++probed )) ${#REX_NVIM_TYPES}
  done
  rm -rf $probe
  ui_progress_clear
  ok "scope rex: file types stay on their apps (see $REX_NVIM_SCOPE_FILE)"
  if (( ${#on} )); then
    warn "still opening with NvimOpen: ${(j:, :)on}"
    ui_detail "to give one back: Finder, Get Info on such a file, Open with, Change All"
  fi
}

rex_nvim_doctor() {
  local tool bin app_bin ext got probe
  local -a wrong kept_elsewhere kept
  doctor_failures=0
  ui_init
  ui_banner doctor

  # The scope decides what the file types check expects, and whether duti
  # is needed at all (the rex scope binds nothing). Empty when unreadable.
  local scope scope_err
  scope_err=$(rex_nvim_scope_read 2>&1 >/dev/null)
  rex_nvim_scope_read 2>/dev/null
  scope=$REPLY

  ui_section "tools"
  for tool in nvim jq perl duti rex; do
    if command -v $tool >/dev/null; then
      ok $tool
    elif [[ $tool == duti && $scope == rex ]]; then
      warn "duti not found: needed only for the global scope"
    else
      fail "$tool not found"
    fi
  done
  command -v glow >/dev/null && ok glow || warn "glow not found: Markdown opens in nvim"

  ui_section "NvimOpen.app"
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

  ui_section "file types"
  if [[ -z $scope ]]; then
    fail "${scope_err#rex-nvim: }"
  elif [[ $scope == rex ]]; then
    rex_nvim_doctor_rex_scope || fail "could not check the file types"
  else
    rex_nvim_keep_read
    kept=($reply)
    integer bound=$(( ${#REX_NVIM_TYPES} - ${#kept} ))
    probe=$(mktemp -d) || return 1
    integer probed=0
    for ext in ${(ko)REX_NVIM_TYPES}; do
      : > $probe/probe.$ext
      got=$(default_app $probe/probe.$ext)
      ui_progress "asking macOS which app opens each type" $(( ++probed )) ${#REX_NVIM_TYPES}
      if (( ${kept[(Ie)$ext]} )); then
        kept_elsewhere+=("$ext -> ${${got:t:r}:-none}")
      elif [[ $got != $REX_NVIM_APP ]]; then
        wrong+=("$ext -> ${${got:t:r}:-none}")
      fi
    done
    rm -rf $probe
    ui_progress_clear
    if (( ${#wrong} )); then
      fail "${#wrong} of $bound types open elsewhere: ${(j:, :)wrong}"
      ui_detail "bind them with: rex-nvim install ${(j: :)${wrong%% *}}"
    else
      ok "all $bound types open with NvimOpen"
    fi
    (( ${#kept_elsewhere} )) && ok "kept on purpose: ${(j:, :)kept_elsewhere} (see $REX_NVIM_KEEP_FILE)"
  fi

  ui_section "browser"
  for probe in https://example.com http://example.com; do
    got=$(default_app $probe)
    if [[ $got == $REX_NVIM_APP ]]; then fail "${probe%%:*} links open with NvimOpen"; else ok "${probe%%:*} -> ${got:t:r}"; fi
  done
  probe=$(mktemp -d)
  : > $probe/probe.html
  got=$(default_app $probe/probe.html)
  rm -rf $probe
  if [[ $got == $REX_NVIM_APP ]]; then fail ".html opens with NvimOpen"; else ok "html -> ${got:t:r}"; fi

  ui_section "Rex"
  # Without Remote Control files still open, but in a session the app is not
  # showing: every click looks like it did nothing.
  local app_client
  app_client=$(rex_app_client)
  if [[ -z $app_client ]]; then
    warn "Rex app not connected"
  elif rex_app_accepts_actions $app_client; then
    ok "Rex app connected, accepts actions"
  else
    fail "Rex app refuses actions: $REPLY"
    ui_detail "files open in a session Rex does not show; turn on Rex Settings > Rex Server > Remote Control"
  fi
  # The config is what decides; running instances are only informative (none
  # is open most of the time a doctor runs).
  local loaded
  ui_spin_start "asking nvim whether its config loads rex-nvim"
  loaded=$(plugin_loaded)
  ui_spin_stop
  case $loaded in
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
  (( live )) || ui_status info "no nvim open in a Rex pane right now"

  print
  if (( ! ui_on )); then
    (( doctor_failures )) && { print "$doctor_failures problem(s) found"; return 1 }
    print "all good"
    return
  fi
  if (( doctor_failures )); then
    ui_status fail "${ui_c[b]}$doctor_failures problem(s) found${ui_c[off]}"
    return 1
  fi
  ui_status ok "${ui_c[b]}all good${ui_c[off]}"
}
