# rex-nvim open FILE[:LINE[:COL]]...: open files from a hyperlink click or a
# Finder double-click (NvimOpen.app calls this).
#
# Each file goes to the registered nvim whose project holds it, and that nvim's
# Rex pane gets the focus. A file no nvim claims, or one whose nvim does not
# answer in time, opens as a new tab of the Rex "files" session (created on
# first use): in nvim, or in glow for Markdown, which is only read there. The
# tab closes when the program exits.

# Seconds to wait for a registered nvim. Busy nvim (:!cmd, a blocking plugin)
# answer only when done; past this the file opens in a tab instead.
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

# rex_nvim_files_tab FILE COMMAND...: run COMMAND in a new tab of the files
# session, with FILE's directory as working directory.
rex_nvim_files_tab() {
  local file=$1 sid
  shift
  sid=$(rex ls --json | jq -r --arg l $REX_NVIM_FILES_SESSION \
    '[.sessions[] | select(.label==$l)][0].session_id // empty') || return
  if [[ -n $sid ]]; then
    rex run -s $sid -c ${file:h} --label ${file:t} -- "$@" >/dev/null
  else
    rex new $REX_NVIM_FILES_SESSION -c ${file:h} --window ${file:t} -- "$@" >/dev/null
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
    notify "nvim on ${meta[1]:t} is busy; ${file:t} opens in a new tab"
    return 1
  fi
  if (( rc != 0 )) || [[ $out != ok ]]; then
    notify "nvim on ${meta[1]:t} could not open ${file:t}: ${out:-exit $rc}"
    return 1
  fi
  return 0
}

rex_nvim_open() {
  (( $# )) || { notify "no file given"; return 64 }
  local tool
  for tool in nvim rex jq perl; do
    command -v $tool >/dev/null || { notify "$tool not found in PATH"; return 69 }
  done

  local arg file line col reg
  local -a cmd
  integer rc=0
  for arg in "$@"; do
    rex_nvim_parse_target $arg
    file=$reply[1] line=$reply[2] col=$reply[3]
    reg=$(rex_nvim_find $file)
    if [[ -n $reg ]] && rex_nvim_send $file $line $col $reg; then
      continue
    fi
    if [[ ${file:e:l} == (md|markdown|mdx) ]] && command -v glow >/dev/null; then
      cmd=(glow -p $file)
    elif (( line > 0 )); then
      cmd=(nvim +$line -- $file)
    else
      cmd=(nvim -- $file)
    fi
    if ! rex_nvim_files_tab $file $cmd; then
      notify "could not open ${file:t} in the Rex \"$REX_NVIM_FILES_SESSION\" session"
      rc=1
    fi
  done
  return $rc
}
