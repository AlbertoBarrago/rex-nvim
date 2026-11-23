# Terminal presentation for the wizard, doctor and install: colors, status
# glyphs, progress, a spinner and single-key input. Styling is on only after
# ui_init finds stdout on a terminal that can show it (ui_on=1); otherwise
# every helper prints the plain text that pipes, logs and test/run.zsh rely
# on. No dependency beyond zsh: escape sequences are written directly.

zmodload zsh/langinfo 2>/dev/null

# Defaults before ui_init, so helpers called by a sourcing script (tests)
# print plain text.
typeset -g ui_on=${ui_on:-0} ui_spin_pid= ui_stty= ui_rows=24 ui_cols=80
typeset -gA ui_c ui_g

# ui_init: set ui_on, ui_c (escape sequences, empty when off or under
# NO_COLOR), ui_g (glyphs, ASCII outside a UTF-8 locale) and the terminal
# size in ui_rows and ui_cols. emacs counts as dumb: zsh never switches
# that terminal out of line mode, so the picker could not read single keys.
ui_init() {
  local size
  ui_on=0
  [[ -t 1 && ${TERM:-dumb} != (dumb|emacs) ]] && ui_on=1
  if (( ui_on )) && [[ -z ${NO_COLOR-} ]]; then
    ui_c=(off $'\e[0m' b $'\e[1m' dim $'\e[2m' red $'\e[31m' green $'\e[32m'
          yellow $'\e[33m' magenta $'\e[35m' cyan $'\e[36m')
  else
    ui_c=(off '' b '' dim '' red '' green '' yellow '' magenta '' cyan '')
  fi
  if [[ ${langinfo[CODESET]:-} == UTF-8 ]]; then
    ui_g=(ok '✓' warn '!' fail '✗' info '·' ask '?' cursor '❯' nvim '◆' keep '◇'
          rule '─' spin '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' move '↑↓' enter '⏎' ellipsis '…')
  else
    ui_g=(ok '+' warn '!' fail 'x' info '-' ask '?' cursor '>' nvim '*' keep 'o'
          rule '-' spin '|/-\' move 'up/down' enter 'enter' ellipsis '~')
  fi
  if (( ui_on )); then
    size=$(stty size </dev/tty 2>/dev/null)
    [[ $size == <1->' '<1-> ]] && { ui_rows=${size%% *}; ui_cols=${size##* } }
    # read -k restores the tty modes only when it returns, so a signal
    # during a key read would leave the terminal without echo: the modes
    # are saved here and put back by ui_cleanup.
    [[ -t 0 ]] && ui_stty=$(stty -g 2>/dev/null)
    # A signal mid-spinner or mid-picker must not leave the cursor hidden,
    # line wrap off or the spinner running.
    trap 'ui_cleanup; print; exit 130' INT
    trap 'ui_cleanup; exit 129' HUP
    trap 'ui_cleanup; exit 143' TERM
  fi
  return 0
}

# ui_cleanup: stop the spinner, show the cursor, turn line wrap back on and
# restore the tty modes saved by ui_init.
ui_cleanup() {
  ui_spin_stop
  (( ui_on )) && print -n -- $'\e[?25h\e[?7h'
  [[ -n $ui_stty ]] && stty $ui_stty 2>/dev/null
  return 0
}

# ui_banner TITLE: the command's heading (nothing in plain mode).
ui_banner() {
  (( ui_on )) || return 0
  print
  print -r -- " ${ui_c[b]}${ui_c[magenta]}rex-nvim${ui_c[off]} ${ui_c[dim]}${ui_g[rule]}${ui_c[off]} ${ui_c[b]}$1${ui_c[off]}"
}

# ui_section TITLE: a section heading, ruled to the terminal width (max 72).
ui_section() {
  if (( ! ui_on )); then
    print -r -- "$1"
    return
  fi
  local rule=${ui_g[rule]}
  integer width=$(( ui_cols < 72 ? ui_cols : 72 )) fill
  fill=$(( width - ${#1} - 4 ))
  (( fill < 0 )) && fill=0
  print
  print -r -- " ${ui_c[b]}${ui_c[cyan]}$1${ui_c[off]} ${ui_c[dim]}${(pl:fill::$rule:)${:-}}${ui_c[off]}"
}

# ui_status KIND MSG: one check result; KIND is ok, warn, fail or info. Plain
# mode keeps the labelled columns doctor has always printed ("  ok    MSG").
ui_status() {
  local kind=$1 label=$1 color
  if (( ! ui_on )); then
    [[ $kind == fail ]] && label=FAIL
    print -r -- "  ${(r:6:)label}$2"
    return
  fi
  case $kind in
    ok) color=green ;;
    warn) color=yellow ;;
    fail) color=red ;;
    *) color=dim ;;
  esac
  print -r -- "  ${ui_c[$color]}${ui_g[$kind]}${ui_c[off]} $2"
}

# ui_say KIND MSG: a message of the wizard or install. Styled like ui_status,
# plain mode prints MSG alone. fail always goes to stderr, styled only when
# stderr is a terminal too, prefixed like every error otherwise.
ui_say() {
  if [[ $1 == fail ]]; then
    if (( ui_on )) && [[ -t 2 ]]; then
      ui_status "$@" >&2
    else
      print -u2 -r -- "rex-nvim: $2"
    fi
  elif (( ui_on )); then
    ui_status "$@"
  else
    print -r -- "$2"
  fi
}

# ui_detail MSG: a continuation line under the previous status.
ui_detail() {
  if (( ui_on )); then
    print -r -- "    ${ui_c[dim]}$1${ui_c[off]}"
  else
    print -r -- "        $1"
  fi
}

# ui_progress LABEL DONE TOTAL: redraw a counter line in place; the frame
# advances with DONE, so a loop of slow probes animates by itself. Line wrap
# is off until ui_progress_clear: a wrapped line could not be redrawn.
ui_progress() {
  (( ui_on )) || return 0
  local frames=${ui_g[spin]}
  print -rn -- $'\e[?7l\r\e[2K'"  ${ui_c[cyan]}${frames[$2 % ${#frames} + 1]}${ui_c[off]} $1 ${ui_c[dim]}$2/$3${ui_c[off]}"
}

# ui_progress_clear: erase the counter line.
ui_progress_clear() {
  (( ui_on )) && print -n -- $'\r\e[2K\e[?7h'
  return 0
}

# ui_spin_start MSG: animate a spinner beside MSG until ui_spin_stop, for a
# single blocking call (asking nvim about its config can take 15 s). The
# loop runs disowned, so the shell prints no job messages for it, and stops
# by itself once this shell is gone (killed by a signal no trap catches).
ui_spin_start() {
  (( ui_on )) || return 0
  local msg=$1 frames=${ui_g[spin]}
  integer parent=$$
  print -n -- $'\e[?25l\e[?7l'
  {
    integer i=0
    while kill -0 $parent 2>/dev/null; do
      print -rn -- $'\r\e[2K'"  ${ui_c[cyan]}${frames[i % ${#frames} + 1]}${ui_c[off]} $msg"
      (( i++ ))
      sleep 0.08
    done
  } &!
  ui_spin_pid=$!
}

# ui_spin_stop: stop the spinner and erase its line. Waits for the loop to be
# gone, or a last frame could land after the line is cleared. SIGKILL also
# ends a stopped loop, and the wait is bounded all the same.
ui_spin_stop() {
  [[ -n $ui_spin_pid ]] || return 0
  integer tries=0
  kill -KILL $ui_spin_pid 2>/dev/null
  while kill -0 $ui_spin_pid 2>/dev/null && (( tries++ < 100000 )); do :; done
  ui_spin_pid=
  print -n -- $'\r\e[2K\e[?25h\e[?7h'
}

# ui_key: read one key from stdin into REPLY: up, down, enter, space, esc,
# other (an unknown escape sequence) or the character itself. Fails at the
# end of input. On a terminal, read takes no -u: only then does zsh switch it
# out of line mode for the read, so a key arrives without Enter. Anything
# else (tests) is read from stdin as given.
ui_key() {
  local k rest
  local -a from=(-u 0)
  [[ -t 0 ]] && from=()
  read -s -k 1 $from k 2>/dev/null || return 1
  case $k in
    $'\e')
      if ! read -s -k 1 -t 0.05 $from rest 2>/dev/null; then
        REPLY=esc
      elif [[ $rest == ('['|O) ]] && read -s -k 1 -t 0.05 $from rest 2>/dev/null; then
        case $rest in
          A) REPLY=up ;;
          B) REPLY=down ;;
          *) REPLY=other ;;
        esac
      else
        REPLY=other
      fi ;;
    $'\n'|$'\r') REPLY=enter ;;
    ' ') REPLY=space ;;
    *) REPLY=$k ;;
  esac
}

# ui_confirm PROMPT: ask a yes/no question answered by one key; only y or Y
# says yes, anything else (or the end of input) says no.
ui_confirm() {
  print -n -- "  ${ui_c[cyan]}${ui_g[ask]}${ui_c[off]} $1 ${ui_c[dim]}[y/N]${ui_c[off]} "
  ui_key || { print; return 1 }
  if [[ $REPLY == [yY] ]]; then
    print -r -- "${ui_c[green]}yes${ui_c[off]}"
    return 0
  fi
  print -r -- "${ui_c[dim]}no${ui_c[off]}"
  return 1
}
