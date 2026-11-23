# Per-user choices: the file types the user keeps on another app (Xcode for
# .swift, say). `rex-nvim install` leaves them alone and `rex-nvim doctor`
# reports them as a choice, not a problem.
#
# The keep file is data, never sourced: one extension per line, `#` starts a
# comment. REX_NVIM_KEEP_FILE exists for tests; NvimOpen.app never reads it.
#
# macOS binds content types (UTIs), not extensions, so extensions sharing a
# type (yaml and yml, js and mjs, ts and tsx) can only be kept together.

source $REX_NVIM_ROOT/lib/types.zsh

REX_NVIM_KEEP_FILE=${REX_NVIM_KEEP_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/rex-nvim/keep}

# rex_nvim_uti_group EXT: set reply to EXT and every extension sharing a
# content type with it, directly or through another one, sorted.
rex_nvim_uti_group() {
  local ext other uti
  local -a group=($1) other_utis
  integer grown=1
  while (( grown )); do
    grown=0
    for ext in $group; do
      for other in ${(k)REX_NVIM_TYPES}; do
        (( ${group[(Ie)$other]} )) && continue
        # A real array: (Ie) on a one-word scalar would match substrings
        # (the kt type is a prefix of the kts one).
        other_utis=(${=REX_NVIM_TYPES[$other]})
        for uti in ${=REX_NVIM_TYPES[$ext]}; do
          if (( ${other_utis[(Ie)$uti]} )); then
            group+=($other)
            grown=1
            break
          fi
        done
      done
    done
  done
  reply=(${(o)group})
}

# rex_nvim_keep_read: set reply to the kept extensions. Unknown extensions,
# and groups kept only in part, are skipped with a warning on stderr: they
# stay bound to NvimOpen, so the doctor keeps pointing at them.
rex_nvim_keep_read() {
  local line ext
  local -a kept valid missing
  reply=()
  [[ -r $REX_NVIM_KEEP_FILE ]] || return 0
  for line in "${(@f)$(<$REX_NVIM_KEEP_FILE)}"; do
    line=${line%%\#*}
    for ext in ${=line}; do
      ext=${ext#.}
      if (( ! ${+REX_NVIM_TYPES[$ext]} )); then
        print -u2 -r -- "rex-nvim: $REX_NVIM_KEEP_FILE: unknown extension: $ext"
        continue
      fi
      kept+=($ext)
    done
  done
  kept=(${(u)kept})
  for ext in $kept; do
    rex_nvim_uti_group $ext
    missing=(${reply:|kept})
    if (( ${#missing} )); then
      print -u2 -r -- "rex-nvim: $REX_NVIM_KEEP_FILE: $ext shares its file type with ${(j:, :)missing}: keep them all or none"
      continue
    fi
    valid+=($ext)
  done
  reply=(${(o)valid})
}

# rex_nvim_keep_write EXT...: replace the keep list with EXT... (no argument
# empties it). Written to a temporary file and moved into place, so a failed
# write never leaves a truncated list behind.
rex_nvim_keep_write() {
  # The real file behind a symlink (a keep list kept in a dotfiles repo):
  # replacing the link itself would cut it off from the repo.
  local file=${REX_NVIM_KEEP_FILE:A} dir tmp
  local -a want=(${(ou)@})
  dir=${file:h}
  # Unchanged list: leave the file, and the user's comments in it, alone.
  if [[ -e $file ]]; then
    rex_nvim_keep_read 2>/dev/null
    [[ ${(j: :)reply} == ${(j: :)want} ]] && return 0
  fi
  mkdir -p $dir || return
  tmp=$(mktemp $dir/.keep.XXXXXX) || return
  {
    print -r -- "# File types rex-nvim leaves on their current app (one extension per line)."
    print -r -- "# Written by rex-nvim install; edit freely."
    if (( ${#want} )); then print -rl -- $want; fi
  } > $tmp && mv $tmp $file || { rm -f $tmp; return 1 }
}
