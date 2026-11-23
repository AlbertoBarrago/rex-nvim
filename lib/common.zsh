# Shared setup for rex-nvim commands. Sourced by bin/rex-nvim.

# LaunchServices starts NvimOpen.app with a bare PATH, so the tools rex-nvim
# needs are appended as fallbacks. Appended, never prepended: from a shell the
# user's own order must win (nvim started by `edit` inherits this PATH, and a
# reordered PATH would give LSPs and :terminal a different node, python...).
# rex ships inside the Rex Server bundle; Versions/Current survives updates.
rex_bin="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS"
typeset -U path
path+=(/opt/homebrew/bin $HOME/.local/bin $rex_bin /usr/local/bin /usr/bin /bin)

# Where running nvim instances register (see lib/registry.zsh and
# nvim/lua/rex-nvim/registry.lua). REX_NVIM_STATE_DIR exists for tests:
# NvimOpen.app never sees shell variables, so changing it in a profile would
# split nvim and `open` apart.
REX_NVIM_STATE=${REX_NVIM_STATE_DIR:-$HOME/.cache/rex-nvim}

# Rex session that receives files no project nvim claims. The server cannot
# tell which of several sessions the app is showing, so a fixed session keeps
# the target predictable.
REX_NVIM_FILES_SESSION=files

# Errors are also logged: notifications can be disabled or missed, and
# NvimOpen.app has no terminal to show them in.
REX_NVIM_LOG=${REX_NVIM_LOG:-$HOME/Library/Logs/rex-nvim.log}

# notify MESSAGE: report an error on stderr, in the log and as a macOS
# notification. The text is passed to osascript as an argument, never
# spliced into AppleScript source.
notify() {
  print -r -- "rex-nvim: $1" >&2
  mkdir -p ${REX_NVIM_LOG:h} 2>/dev/null
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $1" >> $REX_NVIM_LOG 2>/dev/null
  osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "rex-nvim"' -e 'end run' -- "$1" >/dev/null 2>&1
}

# with_timeout SECONDS COMMAND...: run COMMAND, killed by SIGALRM after
# SECONDS (exit status 142). An nvim busy in a blocking command (:!npm test)
# does not answer RPC until it finishes, and the click must not hang on it.
with_timeout() {
  local secs=$1
  shift
  perl -e 'alarm shift; exec @ARGV or exit 127' $secs "$@"
}
