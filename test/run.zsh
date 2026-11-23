#!/bin/zsh
# test/run.zsh: tests for the rex-nvim plugin, registry, `edit` and `open`.
#
# nvim instances are real (headless, with the plugin loaded); `rex` and `glow`
# are stubs that log their arguments, and they come first in PATH for the
# whole suite, so it never touches the user's Rex sessions.
# Usage: zsh test/run.zsh

emulate -R zsh
setopt null_glob pipe_fail
zmodload zsh/datetime

REX_NVIM_ROOT=${0:A:h:h}
real_nvim=$(command -v nvim) || { print -u2 "tests need nvim"; exit 1 }

# Short scratch path: it holds nvim working dirs and the registry.
tmp=$(mktemp -d /tmp/rex-nvim-test.XXXXXX)
tmp=${tmp:A}
typeset -a server_pids
cleanup() {
  (( ${#server_pids} )) && kill $server_pids 2>/dev/null
  rm -rf $tmp
}
trap cleanup EXIT

stubs=$tmp/stubs
mkdir -p $stubs
cat > $stubs/rex <<'EOF'
#!/bin/zsh
print -r -- "rex ${(j: :)${(q)@}}" >> $STUB_LOG
if [[ $1 == ls ]]; then print -r -- ${STUB_SESSIONS:-'{"sessions":[]}'}; fi
EOF
cat > $stubs/glow <<'EOF'
#!/bin/zsh
print -r -- "glow $*" >> $STUB_LOG
EOF
chmod +x $stubs/*
export PATH=$stubs:$PATH STUB_LOG=$tmp/stub.log
export REX_NVIM_STATE_DIR=$tmp/state

source $REX_NVIM_ROOT/lib/common.zsh
source $REX_NVIM_ROOT/lib/registry.zsh
source $REX_NVIM_ROOT/lib/open.zsh
source $REX_NVIM_ROOT/lib/edit.zsh
# common.zsh appends fallbacks to PATH; the stubs must stay first.
path=($stubs ${path:#$stubs})
# notify must not raise macOS notifications during tests.
notify() { print -r -- "notify: $1" >> $tmp/notify.log }

integer failures=0 passes=0
check() {
  local name=$1
  shift
  if "$@"; then
    (( passes++ ))
  else
    (( failures++ ))
    print -r -- "FAIL: $name"
  fi
}

# serve DIR [SESSION]: start a headless nvim in DIR with the plugin loaded, as
# if it ran in Rex block b-<dirname>; set REPLY to its pid once registered.
serve() {
  local dir=$1 session=${2:-s1}
  (
    builtin cd -- $dir
    export REX_BLOCK=b-${dir:t} REX_SESSION=$session
    exec $real_nvim --headless --clean --cmd "set rtp^=$REX_NVIM_ROOT/nvim" -c 'runtime plugin/rex-nvim.lua'
  ) >/dev/null 2>&1 &
  REPLY=$!
  server_pids+=($REPLY)
  repeat 50; do [[ -e $REX_NVIM_STATE_DIR/$REPLY.reg ]] && return 0; sleep 0.1; done
  print -u2 "serve: nvim did not register for $dir"
  return 1
}

# ask PID EXPR: evaluate EXPR in the nvim with PID.
ask() {
  rex_nvim_read_reg $REX_NVIM_STATE_DIR/$1.reg && $real_nvim --server $reply[4] --remote-expr $2 2>/dev/null
}

# --- plugin registration ----------------------------------------------------

work=$tmp/work
parent=$work/app
child=$parent/packages/ui
spaced="$work/my project"
mkdir -p $child "$spaced" $work/application
ln -s $parent $tmp/app-link
for f in $parent/a.ts $child/b.ts "$spaced/c d.ts" $work/application/x.ts; do : > $f; done
print -l one two three four five > $parent/lines.txt

serve $tmp/app-link && pid_parent=$REPLY
rex_nvim_read_reg $REX_NVIM_STATE_DIR/$pid_parent.reg
check "plugin registers the physical root" test "$reply[1]" = $parent
check "plugin registers session and block" test "$reply[2] $reply[3]" = "s1 b-app-link"
check "plugin registers a reachable server" test "$($real_nvim --server $reply[4] --remote-expr 1 2>/dev/null)" = 1

serve $child && pid_child=$REPLY
serve "$spaced" && pid_spaced=$REPLY

found=$(rex_nvim_find $parent/a.ts)
check "file goes to its project's nvim" test "$found" = $REX_NVIM_STATE_DIR/$pid_parent.reg
found=$(rex_nvim_find $child/b.ts)
check "deepest project wins" test "$found" = $REX_NVIM_STATE_DIR/$pid_child.reg
found=$(rex_nvim_find "$spaced/c d.ts")
check "paths with spaces match" test "$found" = $REX_NVIM_STATE_DIR/$pid_spaced.reg
found=$(rex_nvim_find $work/application/x.ts)
check "sibling sharing a name prefix does not match" test -z "$found"

# Two nvim on the same root: the most recently focused (newest mtime) wins.
serve $parent && pid_parent2=$REPLY
touch -t 202001010000 $REX_NVIM_STATE_DIR/$pid_parent.reg
found=$(rex_nvim_find $parent/a.ts)
check "same root: most recent registration wins" test "$found" = $REX_NVIM_STATE_DIR/$pid_parent2.reg
kill $pid_parent2 && wait $pid_parent2 2>/dev/null
check "plugin removes its registration on exit" test ! -e $REX_NVIM_STATE_DIR/$pid_parent2.reg

print -l $work/gone s1 b-gone /nonexistent.sock > $REX_NVIM_STATE_DIR/999999.reg
rex_nvim_live_regs >/dev/null
check "registration of a dead pid is removed" test ! -e $REX_NVIM_STATE_DIR/999999.reg

# --- open: registered nvim ----------------------------------------------------

: > $STUB_LOG
rex_nvim_open $parent/a.ts
check "project file loads in the project's nvim" test "$(ask $pid_parent 'expand("%:p")')" = $parent/a.ts
check "project nvim pane gets the focus" grep -q -- "rex focus -s s1 b-app-link" $STUB_LOG
check "project file never opens a tab" test -z "$(grep 'rex \(new\|run\)' $STUB_LOG)"

rex_nvim_open $parent/lines.txt:4
check "FILE:LINE puts the cursor on the line" test "$(ask $pid_parent 'line(".")')" = 4
rex_nvim_open $parent/lines.txt:2:3
check "FILE:LINE:COL puts the cursor on the column" test "$(ask $pid_parent 'line(".") . ":" . col(".")')" = 2:3

ask $pid_parent 'execute("setlocal winfixbuf")' >/dev/null
rex_nvim_open $child/../../a.ts >/dev/null
rex_nvim_open $parent/lines.txt
check "winfixbuf window keeps its buffer" test "$(ask $pid_parent 'winnr("$")')" = 2

# A busy nvim (blocking :!cmd) must not hang the click: it falls back to a tab.
: > $STUB_LOG
rex_nvim_read_reg $REX_NVIM_STATE_DIR/$pid_spaced.reg
$real_nvim --server $reply[4] --remote-send ':!sleep 8<CR>' 2>/dev/null
sleep 0.3
start=$EPOCHSECONDS
rex_nvim_open "$spaced/c d.ts"
check "busy nvim times out instead of hanging" test $(( EPOCHSECONDS - start )) -le $(( REX_NVIM_SEND_TIMEOUT + 2 ))
check "busy nvim falls back to a tab" grep -q -- "rex new files .*-- nvim --" $STUB_LOG
check "busy nvim is reported" grep -q 'is busy' $tmp/notify.log

# --- open: unclaimed files ---------------------------------------------------

loose=$tmp/loose
mkdir -p $loose
: > $loose/notes.md
print -l a b c > $loose/Main.java

: > $STUB_LOG
rex_nvim_open $loose/notes.md $loose/Main.java
check "markdown opens in glow" grep -q -- "rex new files .*-- glow -p $loose/notes.md" $STUB_LOG
check "other files open in nvim" grep -q -- "rex new files .*-- nvim -- $loose/Main.java" $STUB_LOG

: > $STUB_LOG
rex_nvim_open $loose/Main.java:3
check "FILE:LINE in a new tab starts nvim on the line" grep -q -- "-- nvim +3 -- $loose/Main.java" $STUB_LOG

: > $STUB_LOG
STUB_SESSIONS='{"sessions":[{"session_id":"session:f1","label":"files"}]}' rex_nvim_open $loose/Main.java
check "existing files session is reused" grep -q -- "rex run -s session:f1 .*-- nvim -- $loose/Main.java" $STUB_LOG

: > $loose/odd:7
rex_nvim_parse_target $loose/odd:7
check "an existing name with a colon is not split" test "$reply[1] $reply[2]" = "$loose/odd:7 0"

# --- edit ---------------------------------------------------------------------

nvim_stub=$tmp/nvim-stub
mkdir -p $nvim_stub
cat > $nvim_stub/nvim <<'EOF'
#!/bin/zsh
print -r -- "nvim $*" >> $STUB_LOG
print -r -- "cwd $PWD" >> $STUB_LOG
EOF
chmod +x $nvim_stub/nvim
: > $STUB_LOG
( path=($nvim_stub $path); rex_nvim_edit $parent )
check "edit starts nvim in the directory" grep -qx -- "cwd $parent" $STUB_LOG
check "edit loads the plugin from this clone" grep -q -- "rtp:append(\[==\[$REX_NVIM_ROOT/nvim\]==\])" $STUB_LOG

print "$passes passed, $failures failed"
(( failures == 0 ))
