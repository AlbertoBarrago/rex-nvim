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

# rex_nvim_wizard_rows: fill the global arrays wizard_exts (space-separated
# extensions of a group), wizard_now (apps opening it today, joined with /
# when its members disagree), wizard_suggest (nvim or keep) and wizard_note,
# for every group not fully on NvimOpen; and wizard_on_nvim with the
# extensions that are. Every member is probed: .ts can open in NvimOpen
# through the video type while .tsx opens elsewhere.
rex_nvim_wizard_rows() {
  local ext pat member probe app
  local -a seen kept group apps names
  integer all_nvim owned
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

# rex_nvim_wizard_plugin MODE: offer to load the nvim plugin from the user's
# config when it does not yet. With lazy.nvim importing lua/plugins, a spec
# file goes there; without a plugin manager, a symlink in the pack path loads
# it (lazy.nvim resets the pack path, so that route is for plain configs
# only). Nothing existing is overwritten, and MODE auto only prints the
# suggestion: the user's nvim config is never changed without a yes.
rex_nvim_wizard_plugin() {
  local mode=$1 app=${NVIM_APPNAME:-nvim} cfg target what answer tmp
  local dir=$REX_NVIM_ROOT/nvim
  case $(plugin_loaded) in
    yes) print "nvim config already loads the rex-nvim plugin"; return 0 ;;
    no) ;;
    # No answer proves nothing: never offer to change the config on it.
    *) print "could not ask nvim whether its config loads the plugin: see README, Install"; return 0 ;;
  esac
  # Resolved: BSD grep -r does not follow a symlinked config directory (a
  # config kept in a dotfiles repo), and would miss lazy.nvim in it.
  cfg=${XDG_CONFIG_HOME:-$HOME/.config}/$app
  cfg=${cfg:A}

  if grep -rqsE "require[ (]*[\"']lazy[\"']" $cfg; then
    if [[ ! -d $cfg/lua/plugins ]] || ! grep -rqsE "import *= *[\"']plugins[\"']" $cfg; then
      print "nvim uses lazy.nvim without importing lua/plugins: add the spec from the README (Install) by hand"
      return 0
    fi
    target=$cfg/lua/plugins/rex-nvim.lua
    what="write the lazy.nvim spec $target"
  else
    target=${XDG_DATA_HOME:-$HOME/.local/share}/$app/site/pack/rex-nvim/start/rex-nvim
    what="link $target -> $dir"
  fi
  if [[ -e $target || -L $target ]]; then
    print "nvim does not load the plugin, but $target exists: check it by hand (see README, Install)"
    return 0
  fi

  if [[ $mode != ask ]]; then
    print "to load the nvim plugin: $what"
    return 0
  fi
  print -n -- "nvim does not load the rex-nvim plugin. ${(C)what[1]}${what[2,-1]}? [y/N] "
  read -r answer || return 0
  [[ $answer == [yY]* ]] || { print "left the nvim config alone"; return 0 }

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
    (( written )) || { print -u2 "rex-nvim: could not write $target (it may exist now)"; return 1 }
  else
    # ln -s fails on an existing name, so it never replaces anything either.
    ln -s $dir $target || { print -u2 "rex-nvim: could not link $target"; return 1 }
  fi
  print "done: $what"
}

# rex_nvim_wizard [--yes]: the whole flow. Asks on a terminal; with --yes, or
# without a terminal, takes the suggestions and changes no nvim config.
rex_nvim_wizard() {
  local mode=ask
  [[ ${1:-} == --yes ]] && mode=auto
  [[ -t 0 && -t 1 ]] || mode=auto

  local -a keep
  rex_nvim_install_preflight || return

  print "Which app opens each file type:"
  rex_nvim_wizard_rows || return
  rex_nvim_wizard_table
  if ! rex_nvim_wizard_choose $mode; then
    print "\nstopped: nothing changed"
    return 1
  fi
  keep=($reply)
  # The keep list changes only once the app is in place: a failed build
  # leaves the previous choice as it was.
  rex_nvim_install_app || return
  rex_nvim_keep_write $keep || { print -u2 "rex-nvim: could not write $REX_NVIM_KEEP_FILE"; return 1 }
  rex_nvim_bind ${${(k)REX_NVIM_TYPES}:|keep}
  (( ${#keep} )) && print "keeping on their current app: ${(j:, :)keep}"
  # A failed binding is still reported in the exit status, after the plugin
  # step has had its turn.
  rex_nvim_bind_report
  integer bind_status=$?
  rex_nvim_wizard_plugin $mode
  return bind_status
}
