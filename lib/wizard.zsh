# rex-nvim install with no extension: first ask for the scope (lib/config.zsh):
# global or only inside Rex. Global shows which app opens each file type
# today, suggests nvim or keeping the current app, lets the user accept or
# pick per type, then writes the keep list (lib/config.zsh) and binds the
# rest (lib/install.zsh). Rex builds the app and binds nothing. A last step
# offers to load the nvim plugin from the user's config when it does not yet.
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

# rex_nvim_wizard_rex_app: say whether the Rex app takes the actions a click
# needs. Without Remote Control (Rex Settings, Rex Server) a file opens in a
# session the app does not switch to. Only
# reported, never a failure: the setting is the user's to change, and a Rex
# app not running now proves nothing.
rex_nvim_wizard_rex_app() {
  local app
  app=$(rex_app_client)
  if [[ -z $app ]]; then
    ui_say info "Rex app not running: in its Settings, Rex Server, turn on Remote Control"
  elif rex_app_accepts_actions $app; then
    ui_say ok "Rex app accepts actions (Remote Control on)"
  else
    ui_say warn "Rex app refuses actions: $REPLY"
    ui_say warn "files would open in a session Rex does not show: turn on Remote Control in Rex Settings, Rex Server"
  fi
}

# Shown for each scope, in the picker and the line-by-line question.
typeset -gA REX_NVIM_SCOPE_DESC=(
  global 'Finder double-clicks and file links open in nvim (macOS asks once per file type)'
  rex    'only inside Rex, through rex-nvim:// links; Finder keeps its apps, no macOS dialogs'
)

# rex_nvim_wizard_scope_ask CURRENT: ask for the scope line by line, Enter
# keeps CURRENT; set REPLY to global or rex. Fails when the user quits or
# stdin ends.
rex_nvim_wizard_scope_ask() {
  local answer
  print "Where should files open in nvim?"
  print -r -- "  [g]lobal: $REX_NVIM_SCOPE_DESC[global]"
  print -r -- "  [r]ex:    $REX_NVIM_SCOPE_DESC[rex]"
  while true; do
    print -n -- "[g] or [r], Enter for $1, [q] quit: "
    read -r answer || return 1
    case $answer in
      '') REPLY=$1; return 0 ;;
      g|G) REPLY=global; return 0 ;;
      r|R) REPLY=rex; return 0 ;;
      q|Q) return 1 ;;
    esac
  done
}

# rex_nvim_wizard_scope_pick CURRENT: the terminal picker for the scope,
# starting on CURRENT; set REPLY to global or rex. Arrows or j/k move, Enter
# applies; q, Esc or the end of input fail. Drawn in place like
# rex_nvim_wizard_pick, and two rows fit any terminal.
rex_nvim_wizard_scope_pick() {
  integer cur=1 drawn=0 done=0
  [[ $1 == rex ]] && cur=2

  # _rex_nvim_scope_draw ACTIVE: one frame; the chosen row keeps its mark,
  # and without ACTIVE the key line becomes the choice.
  _rex_nvim_scope_draw() {
    local active=$1 mark name desc line
    local -a out
    integer j room=$(( ui_cols - 3 - 6 - 2 ))
    (( room < 0 )) && room=0
    for (( j = 1; j <= ${#REX_NVIM_SCOPES}; j++ )); do
      mark=' ' name=${(r:6:)REX_NVIM_SCOPES[j]}
      if (( j == cur )); then
        mark="${ui_c[cyan]}${ui_g[cursor]}${ui_c[off]}"
        name="${ui_c[b]}${name}${ui_c[off]}"
      fi
      desc=${REX_NVIM_SCOPE_DESC[${REX_NVIM_SCOPES[j]}]}
      (( ${#desc} > room )) && desc=${desc[1,room]}
      out+=(" $mark ${name}  ${ui_c[dim]}$desc${ui_c[off]}")
    done
    if (( active )); then
      out+=("   ${ui_c[dim]}${ui_g[move]} move  ${ui_g[enter]} apply  q quit${ui_c[off]}")
    else
      out+=("   ${ui_c[dim]}scope: ${REX_NVIM_SCOPES[cur]}${ui_c[off]}")
    fi
    (( drawn )) && print -n -- $'\e['"${drawn}A"
    for line in "${out[@]}"; do
      print -r -- $'\e[2K\r'"$line"
    done
    drawn=${#out}
  }

  (( ui_on )) && print -n -- $'\e[?25l\e[?7l'
  _rex_nvim_scope_draw 1
  while ui_key; do
    case $REPLY in
      up|k) cur=1 ;;
      down|j) cur=2 ;;
      enter) done=1; break ;;
      q|Q|esc) break ;;
    esac
    _rex_nvim_scope_draw 1
  done
  _rex_nvim_scope_draw 0
  unfunction _rex_nvim_scope_draw
  (( ui_on )) && print -n -- $'\e[?25h\e[?7h'
  (( done )) || return 1
  REPLY=${REX_NVIM_SCOPES[cur]}
}

# rex_nvim_wizard_on_nvimopen [PROGRESS]: set reply to the extensions macOS
# opens with NvimOpen today. In the rex scope these are leftovers of a
# global install. PROGRESS is called as in rex_nvim_wizard_rows.
rex_nvim_wizard_on_nvimopen() {
  local progress=${1:-} ext probe
  local -a on
  integer probed=0
  probe=$(mktemp -d) || return 1
  for ext in ${(ko)REX_NVIM_TYPES}; do
    : > $probe/probe.$ext
    [[ $(default_app $probe/probe.$ext) == $REX_NVIM_APP ]] && on+=($ext)
    (( probed++ ))
    [[ -n $progress ]] && $progress $probed ${#REX_NVIM_TYPES}
  done
  rm -rf $probe
  reply=($on)
}

# rex_nvim_wizard_build MODE SCOPE: build and register NvimOpen.app for
# SCOPE, under a spinner in MODE tui.
rex_nvim_wizard_build() {
  local out scope=$2
  [[ $1 == tui ]] || { rex_nvim_install_app $scope; return }
  # Its errors are collected, not printed under the spinner's line. The
  # build has no effect on this shell, so a subshell loses nothing.
  ui_spin_start "building NvimOpen.app"
  out=$(rex_nvim_install_app $scope 2>&1)
  integer build_status=$?
  ui_spin_stop
  if (( build_status )); then
    ui_status fail "${${out#rex-nvim: }:-could not build NvimOpen.app}"
    return build_status
  fi
  ui_status ok "NvimOpen.app built and registered"
}

# rex_nvim_wizard_global MODE: the global scope: pick the file types, build
# the app, bind them. Fails when the user stops or the build fails; a
# failed binding sets bind_status instead, so the later steps still run.
rex_nvim_wizard_global() {
  local mode=$1
  local -a keep
  rex_nvim_install_preflight || return

  if [[ $mode == tui ]]; then
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

  # The keep list and the scope change only once the app is in place: a
  # failed build leaves the previous choice as it was.
  [[ $mode == tui ]] && ui_section Apply
  rex_nvim_wizard_build $mode global || return
  rex_nvim_keep_write $keep || { ui_say fail "could not write $REX_NVIM_KEEP_FILE"; return 1 }
  rex_nvim_scope_write global || { ui_say fail "could not write $REX_NVIM_SCOPE_FILE"; return 1 }
  rex_nvim_bind ${${(k)REX_NVIM_TYPES}:|keep}
  (( ${#keep} )) && ui_say info "keeping on their current app: ${(j:, :)keep}"
  rex_nvim_bind_report
  bind_status=$?
  return 0
}

# rex_nvim_wizard_rex MODE: the rex scope: build the app for its rex-nvim://
# scheme only (claimed by no other app, so no dialog, and no file type
# declared, see rex_nvim_build_app), bind nothing, and point at
# file types a global install left on NvimOpen. They are not handed back
# automatically: the app they had is unknown, and every change would bring
# a macOS dialog again.
rex_nvim_wizard_rex() {
  local mode=$1
  [[ $mode == tui ]] && ui_section Apply
  rex_nvim_wizard_build $mode rex || return
  rex_nvim_scope_write rex || { ui_say fail "could not write $REX_NVIM_SCOPE_FILE"; return 1 }
  ui_say ok "no file type bound: Finder and file:// links keep their apps"
  if [[ $mode == tui ]]; then
    rex_nvim_wizard_on_nvimopen rex_nvim_wizard_scan_progress || { ui_progress_clear; return 1 }
    ui_progress_clear
  else
    rex_nvim_wizard_on_nvimopen || return
  fi
  if (( ${#reply} )); then
    ui_say warn "still opening with NvimOpen from a global install: ${(j:, :)reply}"
    ui_say warn "to give one back: Finder, Get Info on such a file, Open with, Change All"
  fi
  return 0
}

# rex_nvim_wizard [--yes] [--scope global|rex]: the whole flow. It asks for
# the scope first (unless --scope gives it), then runs the scope's steps,
# then the nvim plugin and Rex checks. On a terminal that can show it
# (lib/ui.zsh) it runs the pickers, on a dumb one it asks line by line;
# with --yes, or without a terminal, it keeps the saved scope, takes the
# suggestions and changes no nvim config.
rex_nvim_wizard() {
  local mode=ask scope=
  # Given, even empty: an empty --scope "$VAR" must fail, not ask or bind.
  integer scope_given=0
  while (( $# )); do
    case $1 in
      --yes) mode=auto ;;
      --scope)
        (( $# > 1 )) || { print -u2 "rex-nvim: --scope needs global or rex"; return 64 }
        scope=$2 scope_given=1
        shift ;;
      --scope=*) scope=${1#--scope=} scope_given=1 ;;
      *) print -u2 -r -- "rex-nvim: unknown option: $1"; return 64 ;;
    esac
    shift
  done
  if (( scope_given )) && (( ! ${REX_NVIM_SCOPES[(Ie)$scope]} )); then
    print -u2 -r -- "rex-nvim: unknown scope: $scope (global or rex)"
    return 64
  fi
  [[ -t 0 && -t 1 ]] || mode=auto
  ui_init
  [[ $mode == ask ]] && (( ui_on )) && mode=tui
  # Styling goes with the picker: the line-by-line and automatic runs keep
  # their plain output even when stdout alone is a terminal.
  [[ $mode == tui ]] || ui_on=0

  [[ $mode == tui ]] && ui_banner install
  if (( ! scope_given )); then
    rex_nvim_scope_read || return 1
    case $mode in
      auto) scope=$REPLY ;;
      tui)
        ui_section Scope
        rex_nvim_wizard_scope_pick $REPLY || { print; ui_say warn "stopped: nothing changed"; return 1 }
        scope=$REPLY ;;
      ask)
        rex_nvim_wizard_scope_ask $REPLY || { print "\nstopped: nothing changed"; return 1 }
        scope=$REPLY ;;
    esac
  fi
  [[ $mode == tui ]] || print -r -- "scope: $scope"

  # Set by the global scope's binding step: a failed binding is still
  # reported in the exit status, after the plugin step has had its turn.
  integer bind_status=0
  rex_nvim_wizard_$scope $mode || return

  [[ $mode == tui ]] && ui_section "nvim plugin"
  rex_nvim_wizard_plugin $mode
  [[ $mode == tui ]] && ui_section Rex
  rex_nvim_wizard_rex_app
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
