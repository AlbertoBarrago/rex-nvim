# NvimOpen.app identity and the file types it handles. Sourced by
# lib/install.zsh and lib/doctor.zsh.

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
  mjs   com.netscape.javascript-source
  cjs   $REX_NVIM_BUNDLE_ID.cjs
  cts   $REX_NVIM_BUNDLE_ID.cts
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
  scss  $REX_NVIM_BUNDLE_ID.scss
  txt   public.plain-text
  xml   public.xml
  sql   org.iso.sql
  java  com.sun.java-source
  kt    $REX_NVIM_BUNDLE_ID.kt
  kts   $REX_NVIM_BUNDLE_ID.kts
  gradle $REX_NVIM_BUNDLE_ID.gradle
  properties $REX_NVIM_BUNDLE_ID.properties
  c     public.c-source
  cpp   public.c-plus-plus-source
  h     public.c-header
  hpp   public.c-plus-plus-header
  m     public.objective-c-source
  mm    public.objective-c-plus-plus-source
  rb    public.ruby-script
  php   public.php-script
  # .plist stays out on purpose: macOS types every .plist as the generic
  # com.apple.property-list, binary ones included, and those belong to Xcode.
)

# Extensions macOS has no type for. LaunchServices refuses a default handler
# for the dynamic type it makes up, so NvimOpen imports one for each (an app
# exporting a real type for the extension takes precedence over the import).
REX_NVIM_IMPORTED=(jsx cjs cts lua rs go kt kts gradle properties scss)
