# rex-nvim install with no extension: show which app opens each file type
# today, suggest nvim or keeping the current app, let the user accept or pick
# per type, then write the keep list (lib/config.zsh) and bind the rest
# (lib/install.zsh). A last step offers to load the nvim plugin from the
# user's config when it does not yet.
#
# One row per content-type group, not per extension: macOS binds types, so
# yaml and yml (or ts and tsx) can only move together.

source $REX_NVIM_ROOT/lib/types.zsh
source $REX_NVIM_ROOT/lib/config.zsh
source $REX_NVIM_ROOT/lib/probe.zsh
source $REX_NVIM_ROOT/lib/install.zsh
source $REX_NVIM_ROOT/lib/ui.zsh

# Apps that own a type: when one of them opens it today, keeping it is the
# suggestion (Swift lives in Xcode projects, Gradle scripts in the IDE that
# syncs them). Values are zsh patterns over the app name.
typeset -gA REX_NVIM_OWNERS=(
  swift  'Xcode*'
  m      'Xcode*'
  mm     'Xcode*'
  kt     '(Android Studio*|IntelliJ IDEA*)'
  kts    '(Android Studio*|IntelliJ IDEA*)'
  gradle '(Android Studio*|IntelliJ IDEA*)'
)

# Shown beside a row, whatever the suggestion.
typeset -gA REX_NVIM_NOTES=(
  ts 'binding it also opens .ts videos in nvim'
)

# rex_nvim_wizard_rows [PROGRESS]: fill the global arrays wizard_exts (space-separated
# extensions of a group), wizard_now (apps opening it today, joined with /
# when its members disagree), wizard_suggest (nvim or keep) and wizard_note,
# for every group not fully on NvimOpen; and wizard_on_nvim with the
# extensions that are. Every member is probed: .ts can open in NvimOpen
# through the video type while .tsx opens elsewhere. PROGRESS, when given, is
# called as PROGRESS DONE TOTAL after each probe (one per extension).
rex_nvim_wizard_rows() {
  local progress=${1:-} ext pat member probe app
  local -a seen kept group apps names
  integer all_nvim owned probed=0
  typeset -ga wizard_exts=() wizard_now=() wizard_suggest=() wizard_note=() wizard_on_nvim=()
  rex_nvim_keep_read
  kept=($reply)
  probe=$(mktemp -d) || return 1
  for ext in ${(ko)REX_NVIM_TYPES}; do
    (( ${seen[(Ie)$ext]} )) && continue
    rex_nvim_uti_group $ext
    group=($reply)
    seen+=($group)
    apps=()
    all_nvim=1 owned=0
    for member in $group; do
      : > $probe/probe.$member
      app=$(default_app $probe/probe.$member)
      apps+=("$app")
      (( probed++ ))
      [[ -n $progress ]] && $progress $probed ${#REX_NVIM_TYPES}
      [[ $app == $REX_NVIM_APP ]] || all_nvim=0
      pat=${REX_NVIM_OWNERS[$member]:-}
      [[ -n $pat && ${app:t:r} == ${~pat} ]] && owned=1
    done
    if (( all_nvim )) && (( ! ${kept[(Ie)$ext]} )); then
      wizard_on_nvim+=($group)
      continue
    fi
    names=()
    for app in "${apps[@]}"; do names+=("${${app:t:r}:-none}"); done
    wizard_exts+=("$group")
    wizard_now+=("${(j:/:)${(@u)names}}")
    # An earlier keep stands until the user changes it; otherwise keep only
    # what an owning IDE has.
    if (( ${kept[(Ie)$ext]} || owned )); then
      wizard_suggest+=(keep)
    else
      wizard_suggest+=(nvim)
    fi
    wizard_note+=("${REX_NVIM_NOTES[$ext]:-}")
  done
  rm -rf $probe
}

# rex_nvim_wizard_table: print the rows filled by rex_nvim_wizard_rows.
rex_nvim_wizard_table() {
  integer i
  if (( ${#wizard_exts} )); then
    printf '  %-16s %-20s %s\n' type "opens with now" suggested
    for (( i = 1; i <= ${#wizard_exts}; i++ )); do
      printf '  %-16s %-20s %-5s %s\n' ${${wizard_exts[i]}// /, } ${wizard_now[i]} ${wizard_suggest[i]} ${wizard_note[i]:+"($wizard_note[i])"}
    done
  fi
  (( ${#wizard_on_nvim} )) && print -r -- "  already in nvim: ${#wizard_on_nvim} types"
  return 0
}

# rex_nvim_wizard_choose MODE: decide every row, set reply to the extensions
# to keep. MODE ask reads answers from stdin, MODE auto takes the
# suggestions. Fails when the user quits or stdin ends.
rex_nvim_wizard_choose() {
  local mode=$1 answer pick
  local -a keep
  integer i
  reply=()
  if [[ $mode == ask ]] && (( ${#wizard_exts} )); then
    print -n -- "[Enter] accept the suggestions  [p] pick each type  [q] quit: "
    read -r answer || return 1
    case $answer in
      '') mode=auto ;;
      p|P) ;;
      *) return 1 ;;
    esac
  fi
  for (( i = 1; i <= ${#wizard_exts}; i++ )); do
    pick=${wizard_suggest[i]}
    if [[ $mode == ask ]]; then
      while true; do
        print -n -- "  ${${wizard_exts[i]}// /, } (now ${wizard_now[i]}) [n]vim or [k]eep, Enter for $pick: "
        read -r answer || return 1
        case $answer in
          '') break ;;
          n|N) pick=nvim; break ;;
          k|K) pick=keep; break ;;
          q|Q) return 1 ;;
        esac
      done
    fi
    [[ $pick == keep ]] && keep+=(${=wizard_exts[i]})
  done
  reply=(${(o)keep})
}

# rex_nvim_wizard_scan_progress DONE TOTAL: progress hook for the scan.
rex_nvim_wizard_scan_progress() {
  ui_progress "asking macOS which app opens each type" $1 $2
}

# rex_nvim_wizard_pick: the terminal picker, decides every row like
# rex_nvim_wizard_choose and sets reply the same way. Arrows or j/k move,
# space toggles nvim/keep, a sets every row to nvim, s restores the
# suggestions, Enter applies; q, Esc or the end of input fail.
#
# It draws in place, not on the alternate screen, so the final choice stays
# in the scrollback: every redraw moves the cursor up over the previous one
# and clears each line. That needs a fixed height and no wrapped lines, hence
# the window over long lists, the clipped columns and line wrap turned off
# while it runs (a narrow pane, or one resized meanwhile, truncates instead).
rex_nvim_wizard_pick() {
  local -a pick exts nows
  local str
  integer i n=${#wizard_exts} cur=1 top=1 height drawn=0 w_ext=4 w_now=9 done=0
  pick=("${wizard_suggest[@]}")
  for (( i = 1; i <= n; i++ )); do
    exts+=("${${wizard_exts[i]}// /, }")
    str=${wizard_now[i]}
    (( ${#str} > 24 )) && str="${str[1,23]}${ui_g[ellipsis]}"
    nows+=("$str")
    (( ${#exts[i]} > w_ext )) && w_ext=${#exts[i]}
    (( ${#str} > w_now )) && w_now=${#str}
  done
  # Header, rows, window line, blank, key line, plus the lines around it.
  height=$(( ui_rows - 10 ))
  (( height < 1 )) && height=1
  (( height > n )) && height=n

  # _rex_nvim_wizard_draw ACTIVE: one frame, reading the picker's locals
  # (zsh scoping is dynamic). Without ACTIVE, no cursor and a summary in
  # place of the keys.
  _rex_nvim_wizard_draw() {
    local active=$1 mark name choice note line
    integer j room
    local -a out
    out+=("   ${ui_c[dim]}${(r:w_ext:):-TYPE}  ${(r:w_now:):-OPENS NOW}  CHOICE${ui_c[off]}")
    for (( j = top; j < top + height; j++ )); do
      mark=' ' name=${(r:w_ext:)exts[j]}
      if (( active && j == cur )); then
        mark="${ui_c[cyan]}${ui_g[cursor]}${ui_c[off]}"
        name="${ui_c[b]}${name}${ui_c[off]}"
      fi
      if [[ ${pick[j]} == nvim ]]; then
        choice="${ui_c[green]}${ui_g[nvim]} nvim${ui_c[off]}"
      else
        choice="${ui_c[yellow]}${ui_g[keep]} keep${ui_c[off]}"
      fi
      # Room left for the note once the fixed columns are drawn.
      note=${wizard_note[j]}
      room=$(( ui_cols - 3 - w_ext - 2 - w_now - 2 - 6 - 3 ))
      (( room < 0 )) && room=0
      (( ${#note} > room )) && note=${note[1,room]}
      line=" $mark ${name}  ${ui_c[dim]}${(r:w_now:)nows[j]}${ui_c[off]}  $choice"
      [[ -n $note ]] && line+="  ${ui_c[dim]}$note${ui_c[off]}"
      out+=("$line")
    done
    if (( n > height )); then
      out+=("   ${ui_c[dim]}$top-$(( top + height - 1 )) of $n${ui_c[off]}")
    else
      out+=("")
    fi
    if (( active )); then
      out+=("   ${ui_c[dim]}${ui_g[move]} move  space toggle  a all nvim  s suggested  ${ui_g[enter]} apply  q quit${ui_c[off]}")
    else
      out+=("   ${ui_c[dim]}${#${(@M)pick:#nvim}} to nvim, ${#${(@M)pick:#keep}} kept${ui_c[off]}")
    fi
    (( drawn )) && print -n -- $'\e['"${drawn}A"
    for line in "${out[@]}"; do
      print -r -- $'\e[2K\r'"$line"
    done
    drawn=${#out}
  }

  (( ui_on )) && print -n -- $'\e[?25l\e[?7l'
  _rex_nvim_wizard_draw 1
  while ui_key; do
    case $REPLY in
      up|k) (( cur > 1 )) && (( cur-- )) ;;
      down|j) (( cur < n )) && (( cur++ )) ;;
      space)
        if [[ ${pick[cur]} == nvim ]]; then pick[cur]=keep; else pick[cur]=nvim; fi ;;
      a) pick=("${(@)pick/*/nvim}") ;;
      s) pick=("${wizard_suggest[@]}") ;;
      enter) done=1; break ;;
      q|Q|esc) break ;;
    esac
    (( cur < top )) && top=cur
    (( cur >= top + height )) && top=$(( cur - height + 1 ))
    _rex_nvim_wizard_draw 1
  done
  _rex_nvim_wizard_draw 0
  unfunction _rex_nvim_wizard_draw
  (( ui_on )) && print -n -- $'\e[?25h\e[?7h'
  (( done )) || return 1

  local -a keep
  for (( i = 1; i <= n; i++ )); do
    [[ ${pick[i]} == keep ]] && keep+=(${=wizard_exts[i]})
  done
  reply=(${(o)keep})
}

# rex_nvim_wizard_plugin MODE: offer to load the nvim plugin from the user's
# config when it does not yet. With lazy.nvim importing lua/plugins, a spec
# file goes there; without a plugin manager, a symlink in the pack path loads
# it (lazy.nvim resets the pack path, so that route is for plain configs
# only). Nothing existing is overwritten, and MODE auto only prints the
# suggestion: the user's nvim config is never changed without a yes. MODE
# ask reads the answer as a line, MODE tui as one key.
rex_nvim_wizard_plugin() {
  local mode=$1 app=${NVIM_APPNAME:-nvim} cfg target what answer tmp loaded
  local dir=$REX_NVIM_ROOT/nvim
  ui_spin_start "asking nvim whether its config loads rex-nvim"
  loaded=$(plugin_loaded)
  ui_spin_stop
  case $loaded in
    yes) ui_say ok "nvim config already loads the rex-nvim plugin"; return 0 ;;
    no) ;;
    # No answer proves nothing: never offer to change the config on it.
    *) ui_say warn "could not ask nvim whether its config loads the plugin: see README, Install"; return 0 ;;
  esac
  # Resolved: BSD grep -r does not follow a symlinked config directory (a
  # config kept in a dotfiles repo), and would miss lazy.nvim in it.
  cfg=${XDG_CONFIG_HOME:-$HOME/.config}/$app
  cfg=${cfg:A}

  if grep -rqsE "require[ (]*[\"']lazy[\"']" $cfg; then
    if [[ ! -d $cfg/lua/plugins ]] || ! grep -rqsE "import *= *[\"']plugins[\"']" $cfg; then
      ui_say warn "nvim uses lazy.nvim without importing lua/plugins: add the spec from the README (Install) by hand"
      return 0
    fi
    target=$cfg/lua/plugins/rex-nvim.lua
    what="write the lazy.nvim spec $target"
  else
    target=${XDG_DATA_HOME:-$HOME/.local/share}/$app/site/pack/rex-nvim/start/rex-nvim
    what="link $target -> $dir"
  fi
  if [[ -e $target || -L $target ]]; then
    ui_say warn "nvim does not load the plugin, but $target exists: check it by hand (see README, Install)"
    return 0
  fi

  if [[ $mode == auto ]]; then
    ui_say info "to load the nvim plugin: $what"
    return 0
  fi
  if [[ $mode == tui ]]; then
    ui_confirm "nvim does not load the rex-nvim plugin. ${(C)what[1]}${what[2,-1]}?" ||
      { ui_say info "left the nvim config alone"; return 0 }
  else
    print -n -- "nvim does not load the rex-nvim plugin. ${(C)what[1]}${what[2,-1]}? [y/N] "
    read -r answer || return 0
    [[ $answer == [yY]* ]] || { print "left the nvim config alone"; return 0 }
  fi

  mkdir -p ${target:h} || return
  if [[ $target == *.lua ]]; then
    # Written whole to a temporary file, then hard-linked into place: ln
    # fails if a file appeared meanwhile (a dotfiles sync during the prompt),
    # and a failed write never leaves half a spec behind. The path goes into
    # a Lua long string, which takes it verbatim.
    tmp=$(mktemp ${target:h}/.rex-nvim.XXXXXX) || return
    {
      print -r -- "-- Loads rex-nvim (written by rex-nvim install)."
      print -r -- "local dir = [==[$dir]==]"
      print -r -- 'return {'
      print -r -- '  { dir = dir, name = "rex-nvim", lazy = false, cond = vim.uv.fs_stat(dir) ~= nil },'
      print -r -- '}'
    } > $tmp && ln $tmp $target 2>/dev/null
    integer written=$(( ! $? ))
    rm -f $tmp
    (( written )) || { ui_say fail "could not write $target (it may exist now)"; return 1 }
  else
    # ln -s fails on an existing name, so it never replaces anything either.
    ln -s $dir $target || { ui_say fail "could not link $target"; return 1 }
  fi
  ui_say ok "done: $what"
}

# rex_nvim_wizard [--yes]: the whole flow. On a terminal that can show it
# (lib/ui.zsh) it runs the picker, on a dumb one it asks line by line; with
# --yes, or without a terminal, it takes the suggestions and changes no nvim
# config.
rex_nvim_wizard() {
  local mode=ask out
  [[ ${1:-} == --yes ]] && mode=auto
  [[ -t 0 && -t 1 ]] || mode=auto
  ui_init
  [[ $mode == ask ]] && (( ui_on )) && mode=tui
  # Styling goes with the picker: the line-by-line and automatic runs keep
  # their plain output even when stdout alone is a terminal.
  [[ $mode == tui ]] || ui_on=0

  local -a keep
  rex_nvim_install_preflight || return

  if [[ $mode == tui ]]; then
    ui_banner install
    ui_section Scan
    rex_nvim_wizard_rows rex_nvim_wizard_scan_progress || { ui_progress_clear; return 1 }
    ui_progress_clear
    ui_status ok "${#REX_NVIM_TYPES} types scanned, ${#wizard_on_nvim} already open in nvim"
    ui_section Choose
    if (( ${#wizard_exts} )); then
      rex_nvim_wizard_pick || { print; ui_say warn "stopped: nothing changed"; return 1 }
    else
      reply=()
      ui_status info "nothing to choose"
    fi
  else
    print "Which app opens each file type:"
    rex_nvim_wizard_rows || return
    rex_nvim_wizard_table
    if ! rex_nvim_wizard_choose $mode; then
      print "\nstopped: nothing changed"
      return 1
    fi
  fi
  keep=($reply)

  # The keep list changes only once the app is in place: a failed build
  # leaves the previous choice as it was.
  if [[ $mode == tui ]]; then
    ui_section Apply
    # Its errors are collected, not printed under the spinner's line. The
    # build has no effect on this shell, so a subshell loses nothing.
    ui_spin_start "building NvimOpen.app"
    out=$(rex_nvim_install_app 2>&1)
    integer build_status=$?
    ui_spin_stop
    if (( build_status )); then
      ui_status fail "${${out#rex-nvim: }:-could not build NvimOpen.app}"
      return build_status
    fi
    ui_status ok "NvimOpen.app built and registered"
  else
    rex_nvim_install_app || return
  fi
  rex_nvim_keep_write $keep || { ui_say fail "could not write $REX_NVIM_KEEP_FILE"; return 1 }
  rex_nvim_bind ${${(k)REX_NVIM_TYPES}:|keep}
  (( ${#keep} )) && ui_say info "keeping on their current app: ${(j:, :)keep}"
  # A failed binding is still reported in the exit status, after the plugin
  # step has had its turn.
  rex_nvim_bind_report
  integer bind_status=$?
  [[ $mode == tui ]] && ui_section "nvim plugin"
  rex_nvim_wizard_plugin $mode
  if [[ $mode == tui ]]; then
    print
    if (( bind_status )); then
      ui_status fail "done, with bindings that could not be requested"
    else
      ui_status ok "${ui_c[b]}done${ui_c[off]}"
    fi
  fi
  return bind_status
}
