# rex-nvim open FILE...: open files from a hyperlink click or a Finder
# double-click (NvimOpen.app calls this).
#
# Each file goes to the registered nvim whose project holds it, and that nvim's
# Rex pane gets the focus. A file no nvim claims opens as a new tab of the Rex
# "files" session (created on first use): in nvim, or in glow for Markdown,
# which is only read there. The tab closes when the program exits.

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

# rex_nvim_send FILE BLOCKFILE: load FILE in the registered nvim and focus it.
rex_nvim_send() {
  local file=$1 blk=$2
  local -a meta
  meta=("${(@f)$(<$blk)}")
  if ! nvim --server ${blk:r}.sock --remote $file; then
    notify "could not send ${file:t} to nvim"
    return 1
  fi
  rex focus -s ${meta[2]} ${meta[3]} >/dev/null 2>&1 \
    || notify "opened ${file:t}, but could not focus its nvim pane"
  return 0
}

rex_nvim_open() {
  (( $# )) || { notify "no file given"; return 64 }
  local tool
  for tool in nvim rex jq; do
    command -v $tool >/dev/null || { notify "$tool not found in PATH"; return 69 }
  done

  local file blk
  local -a cmd
  integer rc=0
  for file in "$@"; do
    file=${file:A}
    blk=$(rex_nvim_find $file)
    if [[ -n $blk ]]; then
      rex_nvim_send $file $blk || rc=1
      continue
    fi
    if [[ ${file:e:l} == (md|markdown|mdx) ]] && command -v glow >/dev/null; then
      cmd=(glow -p $file)
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
