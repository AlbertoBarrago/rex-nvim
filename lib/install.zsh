# rex-nvim install [EXT...]: build ~/Applications/NvimOpen.app and make it the
# default app for the file types in lib/types.zsh, so file hyperlinks and Finder
# double-clicks open in nvim inside Rex. Types in the keep list
# (lib/config.zsh) are left on their app. With EXT arguments, only those
# extensions are bound, and they leave the keep list.
#
# macOS asks the user to confirm every default-handler change (one dialog per
# type), so only types not already on NvimOpen are bound: a rerun asks only
# for what is missing. Requires duti (brew install duti).

source $REX_NVIM_ROOT/lib/types.zsh
source $REX_NVIM_ROOT/lib/config.zsh

# rex_nvim_build_app DEST: compile and configure NvimOpen.app at DEST.
rex_nvim_build_app() {
  setopt local_options err_return
  local dest=$1 bin=$REX_NVIM_ROOT/bin/rex-nvim
  local as_path sed_path plist utis_json="" ext
  local -a all_utis

  # Escape the CLI path for the AppleScript string literal (\ and ") and then
  # for the sed replacement (\, & and the | delimiter).
  as_path=${bin//\\/\\\\}
  as_path=${as_path//\"/\\\"}
  sed_path=$(print -rn -- $as_path | sed 's/[\\&|]/\\&/g')
  sed "s|__REX_NVIM_BIN__|$sed_path|" $REX_NVIM_ROOT/macos/NvimOpen.applescript \
    | osacompile -o $dest

  plist=$dest/Contents/Info.plist
  plutil -replace CFBundleIdentifier -string $REX_NVIM_BUNDLE_ID $plist
  plutil -replace CFBundleName -string NvimOpen $plist
  # Background-only: no Dock icon flashing on every click.
  plutil -replace LSUIElement -bool true $plist
  # rex-nvim:// links carry the line, unlike file:// ones (see lib/open.zsh).
  # A scheme only this app claims needs no confirmation dialog.
  plutil -replace CFBundleURLTypes -json '[{"CFBundleURLName": "rex-nvim file link", "CFBundleURLSchemes": ["rex-nvim"]}]' $plist
  # Where the applet looks for the CLI, for `rex-nvim doctor` to check.
  plutil -replace RexNvimBin -string $bin $plist

  for ext in $REX_NVIM_IMPORTED; do
    utis_json+="{
      \"UTTypeIdentifier\": \"$REX_NVIM_BUNDLE_ID.$ext\",
      \"UTTypeDescription\": \".$ext source\",
      \"UTTypeConformsTo\": [\"public.source-code\"],
      \"UTTypeTagSpecification\": {\"public.filename-extension\": [\"$ext\"]}
    },"
  done
  plutil -replace UTImportedTypeDeclarations -json "[${utis_json%,}]" $plist

  # Declare exactly the bound types: LaunchServices refuses an undeclared one.
  all_utis=(${(u)=${(v)REX_NVIM_TYPES}})
  plutil -replace CFBundleDocumentTypes -json "[{
    \"CFBundleTypeName\": \"Source and text\",
    \"CFBundleTypeRole\": \"Editor\",
    \"LSHandlerRank\": \"Alternate\",
    \"LSItemContentTypes\": [$(printf '"%s",' $all_utis | sed 's/,$//')]
  }]" $plist

  codesign --force --sign - $dest 2>/dev/null
  plutil -lint -s $plist
}

# rex_nvim_install_preflight [EXT...]: fail before anything changes when duti
# is missing or an extension is unknown.
rex_nvim_install_preflight() {
  local ext
  command -v duti >/dev/null || { print -u2 "rex-nvim: duti not found, run: brew install duti"; return 69 }
  for ext in $@; do
    (( ${+REX_NVIM_TYPES[$ext]} )) || { print -u2 "rex-nvim: unknown extension: $ext"; return 64 }
  done
}

# rex_nvim_install_app: build NvimOpen.app, put it in place of the installed
# one and register it with LaunchServices.
rex_nvim_install_app() {
  local build
  # Build into a scratch dir and swap only once the app is complete:
  # LaunchServices keeps NvimOpen as default handler, so a half-built or
  # missing app would leave every bound file type with nothing to open it.
  build=$(mktemp -d) || return
  trap "rm -rf ${(q)build}" EXIT
  if ! rex_nvim_build_app $build/NvimOpen.app; then
    print -u2 "rex-nvim: could not build NvimOpen.app; the installed one is untouched"
    return 1
  fi
  mkdir -p ${REX_NVIM_APP:h}
  # The previous app moves into the scratch dir (removed on exit) and comes
  # back if the new one cannot take its place.
  local previous=$build/NvimOpen.previous.app
  if [[ -e $REX_NVIM_APP ]] && ! mv $REX_NVIM_APP $previous; then
    print -u2 "rex-nvim: could not move the installed NvimOpen.app aside; it is untouched"
    return 1
  fi
  if ! mv $build/NvimOpen.app $REX_NVIM_APP; then
    [[ -e $previous ]] && mv $previous $REX_NVIM_APP
    print -u2 "rex-nvim: could not install the new NvimOpen.app; the previous one is back"
    return 1
  fi
  $lsregister -f $REX_NVIM_APP
}

# rex_nvim_bind EXT...: ask macOS to make NvimOpen the default app for the
# content types of EXT..., skipping the ones already on it. Sets the global
# arrays bind_requested, bind_already and bind_failed (content types).
rex_nvim_bind() {
  local ext uti
  typeset -ga bind_requested=() bind_already=() bind_failed=()
  for ext in $@; do
    for uti in ${=REX_NVIM_TYPES[$ext]}; do
      (( ${bind_requested[(Ie)$uti]} + ${bind_already[(Ie)$uti]} + ${bind_failed[(Ie)$uti]} )) && continue
      if [[ $(duti -d $uti 2>/dev/null) == $REX_NVIM_BUNDLE_ID ]]; then
        bind_already+=($uti)
      elif duti -s $REX_NVIM_BUNDLE_ID $uti all; then
        bind_requested+=($uti)
      else
        bind_failed+=($uti)
      fi
    done
  done
}

# rex_nvim_bind_report: print what rex_nvim_bind did; fail when a binding
# could not be requested.
rex_nvim_bind_report() {
  # duti succeeds as soon as the change is requested: macOS applies it only
  # once the user confirms the dialog, so "requested" is all that is known.
  print "NvimOpen at $REX_NVIM_APP: ${#bind_requested} requested, ${#bind_already} already set"
  if (( ${#bind_requested} )); then
    print "Confirm each macOS dialog with \"NvimOpen\", then check with: rex-nvim doctor"
  fi
  if (( ${#bind_failed} )); then
    print -u2 "rex-nvim: could not bind: ${bind_failed[*]}"
    return 1
  fi
}

rex_nvim_install() {
  local ext uti
  local -a selected kept bound group

  rex_nvim_install_preflight $@ || return
  rex_nvim_keep_read
  kept=($reply)
  if (( $# )); then
    # One extension stands for its whole type group: binding only some of
    # the group's types would leave the others (ts videos, say) elsewhere.
    for ext in $@; do
      rex_nvim_uti_group $ext
      selected+=($reply)
    done
    selected=(${(u)selected})
  else
    selected=(${${(k)REX_NVIM_TYPES}:|kept})
    (( ${#kept} )) && print "keeping on their current app: ${(j:, :)kept} (listed in $REX_NVIM_KEEP_FILE)"
  fi

  rex_nvim_install_app || return
  rex_nvim_bind $selected

  # A group leaves the keep list only when none of its types failed: a failed
  # build above, or a failed duti, leaves the user's choice as it was.
  if (( $# )); then
    local member
    for ext in $selected; do
      (( ${bound[(Ie)$ext]} )) && continue
      rex_nvim_uti_group $ext
      group=($reply)
      for member in $group; do
        for uti in ${=REX_NVIM_TYPES[$member]}; do
          (( ${bind_failed[(Ie)$uti]} )) && continue 3
        done
      done
      bound+=($group)
    done
    # A named array: nested in ${#...}, the intersection expands to nothing.
    local -a leaving=(${kept:*bound})
    if (( ${#leaving} )); then
      rex_nvim_keep_write ${kept:|bound} || { print -u2 "rex-nvim: could not update $REX_NVIM_KEEP_FILE"; return 1 }
    fi
  fi
  rex_nvim_bind_report
}
