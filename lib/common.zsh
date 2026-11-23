# Shared setup for rex-nvim commands. Sourced by bin/rex-nvim.

# LaunchServices starts NvimOpen.app with a bare PATH: make sure Homebrew's
# nvim/glow and rex are found. rex ships inside the Rex Server bundle;
# Versions/Current survives Rex updates.
rex_bin="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS"
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH:$rex_bin:/usr/local/bin:/usr/bin:/bin"

# Where running nvim instances register (see lib/registry.zsh).
# REX_NVIM_STATE_DIR exists for tests: NvimOpen.app never sees shell variables,
# so changing it in a profile would split `edit` and `open` apart.
REX_NVIM_STATE=${REX_NVIM_STATE_DIR:-$HOME/.cache/rex-nvim}

# Rex session that receives files no project nvim claims. The server cannot
# tell which of several sessions the app is showing, so a fixed session keeps
# the target predictable.
REX_NVIM_FILES_SESSION=files

# notify MESSAGE: report an error on stderr and as a macOS notification, since
# NvimOpen.app has no terminal. The text is passed as an argument, never
# spliced into AppleScript source.
notify() {
  print -r -- "rex-nvim: $1" >&2
  osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "rex-nvim"' -e 'end run' -- "$1" >/dev/null 2>&1
}
