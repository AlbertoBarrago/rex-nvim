# rex-nvim open FILE[:LINE[:COL]]...: open files from a hyperlink click or a
# Finder double-click (NvimOpen.app calls this).
#
# Where each file goes, first match wins:
#   1. the registered nvim whose working directory holds it (deepest wins);
#   2. a new nvim tab in the Rex session whose terminal sits in the file's
#      project (the deepest terminal cwd above the file), started there so it
#      registers for that project;
#   3. the nvim already running in the Rex "files" session, else a new nvim
#      tab there (the session is created on first use).
# Markdown that no nvim claims (1) opens read-only in glow, in the session of
# 2 or 3. A registered nvim that is busy or fails falls back to 2 and 3.
# The Rex app is launched if needed and shown the target session.

# Seconds to wait for a registered nvim. Busy nvim (:!cmd, a blocking plugin)
# answer only when done; past this the file opens elsewhere.
REX_NVIM_SEND_TIMEOUT=3

# rex_nvim_parse_target ARG: set reply=(FILE LINE COL) from FILE, FILE:LINE or
# FILE:LINE:COL (LINE and COL are 0 when absent). A name that exists as given
# wins, so a file really named "a:1" is never split.
rex_nvim_parse_target() {
  local arg=$1
  if [[ -e $arg ]]; then
    reply=(${arg:A} 0 0)
  elif [[ $arg =~ '^(.+):([0-9]+):([0-9]+)$' && -e $match[1] ]]; then
    reply=(${match[1]:A} $match[2] $match[3])
  elif [[ $arg =~ '^(.+):([0-9]+)$' && -e $match[1] ]]; then
    reply=(${match[1]:A} $match[2] 0)
  else
    reply=(${arg:A} 0 0)
  fi
}

# rex_nvim_send FILE LINE COL REG: focus the registered nvim's pane, then open
# FILE there through the plugin's open() (see nvim/lua/rex-nvim/init.lua).
# Fails, after a notification, when nvim does not answer in time or refuses.
rex_nvim_send() {
  local file=$1 line=$2 col=$3 reg=$4 out expr
  integer rc
  rex_nvim_read_reg $reg || return 1
  local -a meta=($reply)
  # Focus first: anything nvim shows while opening (a message, an error) is
  # then in front of the user.
  rex focus -s $meta[2] $meta[3] >/dev/null 2>&1
  # A Vim string literal: single quotes, with inner quotes doubled.
  expr="luaeval('require(\"rex-nvim\").open(_A[1], _A[2], _A[3])', ['${file//\'/\'\'}', $line, $col])"
  out=$(with_timeout $REX_NVIM_SEND_TIMEOUT nvim --server $meta[4] --remote-expr $expr 2>&1)
  rc=$?
  if (( rc == 142 )); then
    notify "nvim on ${meta[1]:t} is busy; ${file:t} opens elsewhere"
    return 1
  fi
  if (( rc != 0 )) || [[ $out != ok ]]; then
    notify "nvim on ${meta[1]:t} could not open ${file:t}: ${out:-exit $rc}"
    return 1
  fi
  REPLY=$meta[2]
  return 0
}

# rex_nvim_new_tab SESSION DIR LABEL COMMAND...: run COMMAND in a new tab of
# SESSION with DIR as working directory; with SESSION empty, create the files
# session with it. Sets REPLY to the session id.
rex_nvim_new_tab() {
  local sid=$1 dir=$2 label=$3
  shift 3
  if [[ -n $sid ]]; then
    rex run -s $sid -c $dir --label $label -- "$@" >/dev/null || return
    REPLY=$sid
  else
    rex new $REX_NVIM_FILES_SESSION -c $dir --window $label -- "$@" >/dev/null || return
    REPLY=$(rex_session_by_label $REX_NVIM_FILES_SESSION)
  fi
}

# rex_nvim_route FILE LINE COL: open one file per the rules above; set REPLY
# to the session it landed in.
rex_nvim_route() {
  local file=$1 line=$2 col=$3 reg files_sid target_sid dir
  local -a cmd

  reg=$(rex_nvim_find $file)
  if [[ -n $reg ]] && rex_nvim_send $file $line $col $reg; then
    return 0
  fi

  files_sid=$(rex_session_by_label $REX_NVIM_FILES_SESSION)
  local markdown=0
  [[ ${file:e:l} == (md|markdown|mdx) ]] && command -v glow >/dev/null && markdown=1

  if rex_cwd_session $file $files_sid; then
    target_sid=$reply[1] dir=$reply[2]
  else
    target_sid=$files_sid dir=${file:h}
    # One nvim serves the files session: send the file to it when it runs.
    if (( ! markdown )) && [[ -n $files_sid ]]; then
      reg=$(rex_nvim_find_in_session $files_sid)
      if [[ -n $reg ]] && rex_nvim_send $file $line $col $reg; then
        return 0
      fi
    fi
  fi

  if (( markdown )); then
    cmd=(glow -p $file)
  elif (( line > 0 )); then
    cmd=(nvim +$line -- $file)
  else
    cmd=(nvim -- $file)
  fi
  rex_nvim_new_tab "$target_sid" $dir ${file:t} $cmd
}

rex_nvim_open() {
  (( $# )) || { notify "no file given"; return 64 }
  local tool
  for tool in nvim rex jq perl; do
    command -v $tool >/dev/null || { notify "$tool not found in PATH"; return 69 }
  done

  local app arg shown
  app=$(rex_ensure_app) || notify "the Rex app is not running; files open in the background"

  integer rc=0
  for arg in "$@"; do
    rex_nvim_parse_target $arg
    if rex_nvim_route $reply[1] $reply[2] $reply[3]; then
      shown=$REPLY
    else
      notify "could not open ${reply[1]:t} in Rex"
      rc=1
    fi
  done
  # Show where the last file landed.
  [[ -n $app && -n $shown ]] && rex_show_session $app $shown
  return $rc
}
