# rex-nvim install [EXT...]: build ~/Applications/NvimOpen.app and make it the
# default app for the file types in lib/types.zsh, so file hyperlinks and Finder
# double-clicks open in nvim inside Rex. With EXT arguments, only those
# extensions are bound.
#
# macOS asks the user to confirm every default-handler change (one dialog per
# type), so only types not already on NvimOpen are bound: a rerun asks only
# for what is missing. Requires duti (brew install duti).

source $REX_NVIM_ROOT/lib/types.zsh

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

rex_nvim_install() {
  local ext uti build
  local -a selected requested already failed

  command -v duti >/dev/null || { print -u2 "rex-nvim: duti not found, run: brew install duti"; return 69 }
  selected=(${@:-${(k)REX_NVIM_TYPES}})
  for ext in $selected; do
    (( ${+REX_NVIM_TYPES[$ext]} )) || { print -u2 "rex-nvim: unknown extension: $ext"; return 64 }
  done

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
  $lsregister -f $REX_NVIM_APP || return

  for ext in $selected; do
    for uti in ${=REX_NVIM_TYPES[$ext]}; do
      if [[ $(duti -d $uti 2>/dev/null) == $REX_NVIM_BUNDLE_ID ]]; then
        already+=($uti)
      elif duti -s $REX_NVIM_BUNDLE_ID $uti all; then
        requested+=($uti)
      else
        failed+=($uti)
      fi
    done
  done
  # duti succeeds as soon as the change is requested: macOS applies it only
  # once the user confirms the dialog, so "requested" is all that is known.
  print "NvimOpen at $REX_NVIM_APP: ${#requested} requested, ${#already} already set"
  if (( ${#requested} )); then
    print "Confirm each macOS dialog with \"NvimOpen\", then check with: rex-nvim doctor"
  fi
  if (( ${#failed} )); then
    print -u2 "rex-nvim: could not bind: ${failed[*]}"
    return 1
  fi
}
