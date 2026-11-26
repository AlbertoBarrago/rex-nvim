# Reading the registry of nvim instances running in Rex panes.
#
# The nvim plugin (nvim/lua/rex-nvim/registry.lua) writes
# $REX_NVIM_STATE/<pid>.reg with four lines: the physical working directory
# (the project root), the Rex session id, the Rex block id and the nvim RPC
# address. It refreshes the file when the pane gains focus, so the newest
# mtime marks the most recently used nvim.

# Seconds to wait for a registered nvim. Busy nvim (:!cmd, a blocking plugin)
# answer only when done; past this `open` sends the file elsewhere.
REX_NVIM_SEND_TIMEOUT=3

# rex_nvim_read_reg FILE: set reply=(ROOT SESSION BLOCK SERVER), or fail when
# FILE is malformed. SESSION is empty when the pane had no $REX_SESSION (Rex
# no longer exports it); rex_nvim_reg_session resolves it from BLOCK. Copy
# reply quoted ("${reply[@]}"): an unquoted copy drops the empty SESSION and
# shifts BLOCK and SERVER down one place.
rex_nvim_read_reg() {
  reply=("${(@f)$(<$1)}")
  (( ${#reply} == 4 )) && [[ -n $reply[1] && -n $reply[4] ]]
}

# rex_nvim_live_regs: print live registration files, newest first, and remove
# the ones whose nvim has exited (crash, kill -9, closed pane).
rex_nvim_live_regs() {
  local reg pid
  for reg in $REX_NVIM_STATE/*.reg(om); do
    pid=${reg:t:r}
    if [[ $pid != <-> ]] || ! kill -0 $pid 2>/dev/null; then
      rm -f $reg
      continue
    fi
    print -r -- $reg
  done
}

# rex_nvim_find FILE: print the registration of the nvim whose project holds
# FILE (an absolute physical path). The deepest root wins; among nvim on the
# same root, the most recently focused one.
rex_nvim_find() {
  local file=$1 reg best
  integer best_len=0
  for reg in ${(f)"$(rex_nvim_live_regs)"}; do
    rex_nvim_read_reg $reg || continue
    [[ $file == $reply[1]/* ]] || continue
    # Strictly greater: on a tie the newer registration, listed first, stays.
    (( ${#reply[1]} > best_len )) || continue
    best=$reg best_len=${#reply[1]}
  done
  [[ -n $best ]] && print -r -- $best
}

# rex_nvim_reg_session SESSION BLOCK: print SESSION, or when it is empty the
# session Rex says holds BLOCK (needs lib/rex.zsh).
rex_nvim_reg_session() {
  if [[ -n $1 ]]; then
    print -r -- $1
  else
    rex_block_session $2
  fi
}

# rex_nvim_find_in_session SESSION: print the most recently focused live
# registration in SESSION, whatever its root.
rex_nvim_find_in_session() {
  local reg
  for reg in ${(f)"$(rex_nvim_live_regs)"}; do
    rex_nvim_read_reg $reg || continue
    if [[ "$(rex_nvim_reg_session "$reply[2]" "$reply[3]")" == $1 ]]; then
      print -r -- $reg
      return 0
    fi
  done
  return 1
}

# rex_nvim_ping SERVER: ask the nvim at the RPC address SERVER to evaluate 1.
# Returns 0 when it answers, 142 when it stays silent past
# REX_NVIM_SEND_TIMEOUT (busy), 1 when the address is unreachable (a live pid
# whose socket was removed or belongs to nothing).
rex_nvim_ping() {
  local out
  out=$(with_timeout $REX_NVIM_SEND_TIMEOUT nvim --server $1 --remote-expr 1 2>/dev/null)
  case $? in
    0) [[ $out == 1 ]] ;;
    142) return 142 ;;
    *) return 1 ;;
  esac
}
