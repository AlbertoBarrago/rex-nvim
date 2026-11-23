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
# The rex stub answers from fixtures in $STUB_FIX: sessions.json (rex ls),
# blocks-<session>.json (rex block ls), pwd-<block>.json (block call pwd);
# $STUB_APP, when set, is the connected app client.
cat > $stubs/rex <<'EOF'
#!/bin/zsh
print -r -- "rex ${(j: :)${(q)@}}" >> $STUB_LOG
fix() { [[ -r $STUB_FIX/$1 ]] && cat $STUB_FIX/$1 || print -r -- $2 }
case "$1 $2" in
  "ls "*) fix sessions.json '{"sessions":[]}' ;;
  "client ls")
    if [[ -n ${STUB_APP:-} ]]; then
      print -r -- "{\"clients\":[{\"client_id\":\"$STUB_APP\",\"info\":{\"kind\":\"app\"},\"connection_state\":\"connected\"}]}"
    else
      print -r -- '{"clients":[]}'
    fi ;;
  "block ls") fix blocks-$4.json '{"blocks":[]}' ;;
  "block call") fix pwd-$6.json '{}' ;;
esac
EOF
cat > $stubs/glow <<'EOF'
#!/bin/zsh
print -r -- "glow $*" >> $STUB_LOG
EOF
# `open -b` would bring the real Rex app to the front.
cat > $stubs/open <<'EOF'
#!/bin/zsh
print -r -- "open $*" >> $STUB_LOG
EOF
chmod +x $stubs/*
export PATH=$stubs:$PATH STUB_LOG=$tmp/stub.log STUB_FIX=$tmp/fix STUB_APP=client:app
export REX_NVIM_STATE_DIR=$tmp/state
mkdir -p $STUB_FIX

source $REX_NVIM_ROOT/lib/common.zsh
source $REX_NVIM_ROOT/lib/registry.zsh
source $REX_NVIM_ROOT/lib/rex.zsh
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
print -r -- '{"sessions":[{"session_id":"session:f1","label":"files"}]}' > $STUB_FIX/sessions.json
rex_nvim_open $loose/Main.java
check "existing files session is reused" grep -q -- "rex run -s session:f1 .*-- nvim -- $loose/Main.java" $STUB_LOG
check "the app is shown the target session" grep -q -- "rex do -C client:app session.select session_id=session:f1" $STUB_LOG

# One nvim serves the files session: further unclaimed files go to it.
filesdir=$tmp/filesdir
mkdir -p $filesdir
serve $filesdir session:f1 && pid_files=$REPLY
: > $STUB_LOG
rex_nvim_open $loose/Main.java
check "files session nvim receives unclaimed files" test "$(ask $pid_files 'expand("%:p")')" = $loose/Main.java
check "files session nvim means no new tab" test -z "$(grep 'rex \(new\|run\)' $STUB_LOG)"
: > $STUB_LOG
rex_nvim_open $loose/notes.md
check "markdown still opens in glow beside the files nvim" grep -q -- "rex run -s session:f1 .*-- glow -p $loose/notes.md" $STUB_LOG

# A terminal sitting in the file's project claims it: new nvim tab there.
proj2=$tmp/proj2
mkdir -p $proj2/src
: > $proj2/src/util.py
print -r -- '{"sessions":[{"session_id":"session:f1","label":"files"},{"session_id":"session:p2","label":"P2"},{"session_id":"session:hm","label":"home"}]}' > $STUB_FIX/sessions.json
print -r -- '{"blocks":[{"block_id":"block:p2a","flavor":"com.superlogical.terminal.shell"}]}' > $STUB_FIX/blocks-session:p2.json
print -r -- '{"blocks":[{"block_id":"block:hm","flavor":"com.superlogical.terminal.shell"}]}' > $STUB_FIX/blocks-session:hm.json
print -r -- "{\"pwd\":\"file://somehost${proj2// /%20}\"}" > $STUB_FIX/pwd-block:p2a.json
print -r -- "{\"pwd\":\"file://somehost$HOME\"}" > $STUB_FIX/pwd-block:hm.json
: > $STUB_LOG
rex_nvim_open $proj2/src/util.py
check "terminal cwd claims the file for its session" grep -q -- "rex run -s session:p2 -c $proj2 --label util.py -- nvim -- $proj2/src/util.py" $STUB_LOG
# A shell sitting in HOME would be an ancestor of every file under it.
mkdir -p $tmp/other
: > $tmp/other/x.py
print -r -- "{\"pwd\":\"file://somehost$tmp\"}" > $STUB_FIX/pwd-block:hm.json
: > $STUB_LOG
HOME=$tmp rex_nvim_open $tmp/other/x.py
check "a shell in HOME does not claim files" test -z "$(grep 'session:hm -c' $STUB_LOG)"

# No Rex app connected: it is launched, and the user told if it never shows.
: > $STUB_LOG
: > $tmp/notify.log
STUB_APP= rex_nvim_open $loose/Main.java
check "missing Rex app is launched" grep -q -- "open -g -b com.superlogical.rex" $STUB_LOG
check "missing Rex app is reported" grep -q 'not running' $tmp/notify.log

rex_nvim_parse_target "rex-nvim://open${loose// /%20}/Main.java?line=12&column=4"
check "rex-nvim:// link gives file, line and column" test "$reply" = "$loose/Main.java 12 4"
rex_nvim_parse_target "rex-nvim://open$tmp/my%20dir/a.ts?col=2&line=7&x=\$(id)"
check "rex-nvim:// link decodes the path and ignores other keys" test "$reply" = "$tmp/my dir/a.ts 7 2"
: > $STUB_LOG
rex_nvim_open "rex-nvim://open$loose/Main.java?line=2"
check "rex-nvim:// link opens like FILE:LINE" grep -q -- "nvim +2 -- $loose/Main.java\|$loose/Main.java" $STUB_LOG

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

# --- file type table (lib/types.zsh) ---------------------------------------

source $REX_NVIM_ROOT/lib/types.zsh
typeset -a own_types missing_imports generic
for ext uti in ${(kv)REX_NVIM_TYPES}; do
  for uti in ${=uti}; do
    [[ $uti == $REX_NVIM_BUNDLE_ID.* ]] && own_types+=(${uti#$REX_NVIM_BUNDLE_ID.})
    [[ $uti == (public.data|public.text|public.item|public.content|public.html|public.url) ]] && generic+=($uti)
  done
done
for ext in $own_types; do
  (( ${REX_NVIM_IMPORTED[(Ie)$ext]} )) || missing_imports+=($ext)
done
check "every NvimOpen-owned type is imported" test -z "${missing_imports[*]}"
check "no generic or browser types are bound" test -z "${generic[*]}"
check "html is never bound" test -z "${REX_NVIM_TYPES[html]:-}${REX_NVIM_TYPES[htm]:-}"

# --- keep list (lib/config.zsh) ----------------------------------------------

export REX_NVIM_KEEP_FILE=$tmp/config/rex-nvim/keep
source $REX_NVIM_ROOT/lib/config.zsh

rex_nvim_uti_group yml
check "extensions sharing a type form one group" test "$reply" = "yaml yml"
rex_nvim_uti_group tsx
check "groups follow every type of an extension" test "$reply" = "ts tsx"
rex_nvim_uti_group swift
check "an extension with its own type is a group of one" test "$reply" = swift

rex_nvim_keep_read
check "missing keep file keeps nothing" test -z "$reply"

rex_nvim_keep_write swift m swift
check "keep file is written with its directory" test -r $REX_NVIM_KEEP_FILE
rex_nvim_keep_read
check "keep file round-trips, sorted and unique" test "$reply" = "m swift"

print -l '# comment' '' '.swift  # Xcode' 'nope' 'yml' 'js mjs' > $REX_NVIM_KEEP_FILE
rex_nvim_keep_read 2> $tmp/keep.err
check "comments, dots and several per line are read" test "$reply" = "js mjs swift"
check "unknown extension is reported" grep -q 'unknown extension: nope' $tmp/keep.err
check "half a type group is reported and not kept" grep -q 'yml shares its file type with yaml' $tmp/keep.err

rex_nvim_keep_write
rex_nvim_keep_read
check "writing no extension empties the list" test -z "$reply"

# --- doctor -------------------------------------------------------------------

source $REX_NVIM_ROOT/lib/doctor.zsh
# Stubs over the system queries: swift and m open in Xcode, the rest in
# NvimOpen; the nvim config loads the plugin unless STUB_PLUGIN says
# otherwise (empty: nvim did not answer).
default_app() {
  case $1 in
    *.swift|*.m) print /Applications/Xcode.app ;;
    *://*|*.html) print /Applications/Safari.app ;;
    *) print $REX_NVIM_APP ;;
  esac
}
plugin_loaded() { print -r -- ${STUB_PLUGIN-yes} }
integer all_types=${#REX_NVIM_TYPES}

rex_nvim_keep_write
rex_nvim_doctor > $tmp/doctor.out 2>&1
check "doctor fails on types open elsewhere" grep -q "FAIL  2 of $all_types types open elsewhere: m -> Xcode, swift -> Xcode" $tmp/doctor.out

rex_nvim_keep_write swift m
rex_nvim_doctor > $tmp/doctor.out 2>&1
check "kept types do not fail" test -z "$(grep 'types open elsewhere' $tmp/doctor.out)"
check "kept types are listed as a choice" grep -q 'ok    kept on purpose: m -> Xcode, swift -> Xcode' $tmp/doctor.out
check "kept types leave the bound count" grep -q "all $(( all_types - 2 )) types open with NvimOpen" $tmp/doctor.out
check "loaded plugin is reported" grep -q 'ok    nvim config loads the rex-nvim plugin' $tmp/doctor.out

STUB_PLUGIN=no rex_nvim_doctor > $tmp/doctor.out 2>&1
check "missing plugin in the config fails" grep -q 'FAIL  nvim config does not load' $tmp/doctor.out
STUB_PLUGIN= rex_nvim_doctor > $tmp/doctor.out 2>&1
check "nvim that does not answer only warns" grep -q 'warn  could not ask nvim' $tmp/doctor.out

print "$passes passed, $failures failed"
(( failures == 0 ))
