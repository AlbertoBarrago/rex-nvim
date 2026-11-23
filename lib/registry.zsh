# Registry of running nvim instances, one per project.
#
# Each registered nvim listens on $REX_NVIM_STATE/<hash>.sock, where <hash> is
# a short sha256 of the project's physical root (symlinks resolved). Hashing
# keeps the path under the 104-byte sun_path limit whatever the project depth.
# The <hash>.block file beside the socket holds three lines: the project root,
# the Rex session id and the Rex block id of the pane running that nvim.

# rex_nvim_paths ROOT: set reply=(SOCKET BLOCKFILE) for project ROOT.
rex_nvim_paths() {
  local hash
  hash=$(print -rn -- $1 | shasum -a 256 | cut -c1-16)
  reply=($REX_NVIM_STATE/$hash.sock $REX_NVIM_STATE/$hash.block)
}

# rex_nvim_alive SOCKET: succeed if an nvim answers on SOCKET.
rex_nvim_alive() {
  [[ -S $1 ]] && nvim --server $1 --remote-expr 1 >/dev/null 2>&1
}

# rex_nvim_find FILE: print the block file of the nvim whose project holds
# FILE (an absolute physical path). The deepest matching root wins, so a nvim
# on a subproject beats one on its parent.
rex_nvim_find() {
  local file=$1 blk best
  local -a meta
  integer best_len=0
  for blk in $REX_NVIM_STATE/*.block; do
    meta=("${(@f)$(<$blk)}")
    (( ${#meta} == 3 )) || continue
    [[ $file == ${meta[1]}/* ]] || continue
    (( ${#meta[1]} > best_len )) || continue
    if [[ ! -S ${blk:r}.sock ]]; then
      # Left by an nvim that exited without cleaning up.
      rm -f $blk
      continue
    fi
    # A socket that does not answer (nvim busy in a blocking command) is
    # skipped for this file, never removed: the nvim may still be alive.
    rex_nvim_alive ${blk:r}.sock || continue
    best=$blk best_len=${#meta[1]}
  done
  [[ -n $best ]] && print -r -- $best
}
