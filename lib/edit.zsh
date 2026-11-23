# rex-nvim edit [DIR]: start nvim in DIR and register it for DIR's project,
# so `rex-nvim open` sends files under DIR to it and focuses its Rex pane.

rex_nvim_edit() {
  local dir=${1:-.}
  builtin cd -- $dir || return
  command -v nvim >/dev/null || { notify "nvim not found in PATH"; return 69 }

  # Outside Rex there is no pane to focus: plain nvim.
  if [[ -z ${REX_BLOCK:-} ]]; then
    exec nvim .
  fi

  local root=${PWD:A} sock blk
  rex_nvim_paths $root
  sock=$reply[1] blk=$reply[2]
  mkdir -p $REX_NVIM_STATE

  if rex_nvim_alive $sock; then
    # Another nvim already serves this project: this one stays unregistered.
    nvim .
    return
  fi

  rm -f $sock
  print -rl -- $root ${REX_SESSION:-} $REX_BLOCK > $blk
  nvim --listen $sock .
  local rc=$?
  # Clean up only what is still ours: a later `edit` on this project may have
  # taken the registration over while this nvim ran.
  if [[ -r $blk && $(sed -n 3p $blk) == $REX_BLOCK ]]; then
    rm -f $sock $blk
  fi
  return $rc
}
