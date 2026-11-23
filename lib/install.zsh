# rex-nvim install [EXT...]: build ~/Applications/NvimOpen.app and make it the
# default app for the file types below, so file hyperlinks and Finder
# double-clicks open in nvim inside Rex. With EXT arguments, only those
# extensions are bound.
#
# macOS asks the user to confirm every default-handler change (one dialog per
# type), so only types not already on NvimOpen are bound: a rerun asks only
# for what is missing. Requires duti (brew install duti).

REX_NVIM_APP=$HOME/Applications/NvimOpen.app
# Kept from the dotfiles prototype so existing bindings survive the move.
REX_NVIM_BUNDLE_ID=it.albz.nvimopen
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Extension -> content types (UTIs) to bind. Binding exact types, never an
# extension, keeps unrelated types sharing the extension out. Never add
# generic types (public.data, public.text, public.item): macOS would offer
# NvimOpen for every file. html/htm stay out: binding public.html makes the
# app the default web browser.
typeset -gA REX_NVIM_TYPES=(
  # macOS classifies .ts as an MPEG-2 video first, so TypeScript sources only
  # reach nvim if the video type is bound too (.ts videos then open in nvim).
  ts    "com.microsoft.typescript public.mpeg-2-transport-stream"
  tsx   com.microsoft.typescript
  js    com.netscape.javascript-source
  jsx   $REX_NVIM_BUNDLE_ID.jsx
  json  public.json
  md    net.daringfireball.markdown
  py    public.python-script
  swift public.swift-source
  lua   $REX_NVIM_BUNDLE_ID.lua
  rs    $REX_NVIM_BUNDLE_ID.rs
  go    $REX_NVIM_BUNDLE_ID.go
  sh    public.shell-script
  zsh   public.zsh-script
  toml  public.toml
  yaml  public.yaml
  yml   public.yaml
  css   public.css
  txt   public.plain-text
  xml   public.xml
  sql   org.iso.sql
  java  com.sun.java-source
  kt    $REX_NVIM_BUNDLE_ID.kt
  c     public.c-source
  cpp   public.c-plus-plus-source
  h     public.c-header
  m     public.objective-c-source
  rb    public.ruby-script
  php   public.php-script
  # .plist stays out on purpose: macOS types every .plist as the generic
  # com.apple.property-list, binary ones included, and those belong to Xcode.
)

# Extensions macOS has no type for. LaunchServices refuses a default handler
# for the dynamic type it makes up, so NvimOpen imports one for each (an app
# exporting a real type for the extension takes precedence over the import).
REX_NVIM_IMPORTED=(jsx lua rs go kt)

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
  local -a selected bound already failed

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
  # The previous app moves into the scratch dir, removed on exit.
  [[ -e $REX_NVIM_APP ]] && mv $REX_NVIM_APP $build/NvimOpen.previous.app
  mv $build/NvimOpen.app $REX_NVIM_APP || return
  $lsregister -f $REX_NVIM_APP || return

  for ext in $selected; do
    for uti in ${=REX_NVIM_TYPES[$ext]}; do
      if [[ $(duti -d $uti 2>/dev/null) == $REX_NVIM_BUNDLE_ID ]]; then
        already+=($uti)
      elif duti -s $REX_NVIM_BUNDLE_ID $uti all; then
        bound+=($uti)
      else
        failed+=($uti)
      fi
    done
  done
  print "NvimOpen at $REX_NVIM_APP: ${#bound} bound, ${#already} already set"
  if (( ${#bound} )); then
    print "Confirm each macOS dialog with \"NvimOpen\" to apply the new bindings."
  fi
  if (( ${#failed} )); then
    print -u2 "rex-nvim: could not bind: ${failed[*]}"
    return 1
  fi
}
