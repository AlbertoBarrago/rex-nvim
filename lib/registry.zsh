# Reading the registry of nvim instances running in Rex panes.
#
# The nvim plugin (nvim/lua/rex-nvim/registry.lua) writes
# $REX_NVIM_STATE/<pid>.reg with four lines: the physical working directory
# (the project root), the Rex session id, the Rex block id and the nvim RPC
# address. It refreshes the file when the pane gains focus, so the newest
# mtime marks the most recently used nvim.

# rex_nvim_read_reg FILE: set reply=(ROOT SESSION BLOCK SERVER), or fail when
# FILE is malformed.
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

# rex_nvim_find_in_session SESSION: print the most recently focused live
# registration in SESSION, whatever its root.
rex_nvim_find_in_session() {
  local reg
  for reg in ${(f)"$(rex_nvim_live_regs)"}; do
    rex_nvim_read_reg $reg || continue
    if [[ $reply[2] == $1 ]]; then
      print -r -- $reg
      return 0
    fi
  done
  return 1
}
