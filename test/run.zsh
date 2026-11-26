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
# blocks-<session>.json (rex block ls), pwd-<block>.json (block call pwd),
# windows-<session>.json (rex window ls); `rex run --json` answers with the
# new tab's window $STUB_NEW_WINDOW (window:new by default);
# $STUB_APP, when set, is the connected app client; $STUB_REFUSE, when set,
# makes the app refuse every action, as Rex does with Remote Control off.
cat > $stubs/rex <<'EOF'
#!/bin/zsh
print -r -- "rex ${(j: :)${(q)@}}" >> $STUB_LOG
fix() { [[ -r $STUB_FIX/$1 ]] && cat $STUB_FIX/$1 || print -r -- $2 }
case "$1 $2" in
  "do "*)
    if [[ -n ${STUB_REFUSE:-} ]]; then
      print -u2 "Error: Rex.app is not accepting actions. Turn on Remote Control."
      exit 1
    fi ;;
  "ls "*) fix sessions.json '{"sessions":[]}' ;;
  "client ls")
    if [[ -n ${STUB_APP:-} ]]; then
      print -r -- "{\"clients\":[{\"client_id\":\"$STUB_APP\",\"info\":{\"kind\":\"app\"},\"connection_state\":\"connected\"}]}"
    else
      print -r -- '{"clients":[]}'
    fi ;;
  "block ls") fix blocks-$4.json '{"blocks":[]}' ;;
  "window ls") fix windows-$4.json '{"windows":[]}' ;;
  "run "*)
    [[ " $* " == *" --json "* ]] && print -r -- "{\"window_id\":\"${STUB_NEW_WINDOW:-window:new}\"}" ;;
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

rex_nvim_read_reg $REX_NVIM_STATE_DIR/$pid_parent.reg
check "ping: a running nvim answers" rex_nvim_ping $reply[4]
rex_nvim_ping $tmp/nonexistent.sock
check "ping: a missing socket is unreachable" test $? -eq 1

# --- open: registered nvim ----------------------------------------------------

: > $STUB_LOG
rex_nvim_open $parent/a.ts
check "project file loads in the project's nvim" test "$(ask $pid_parent 'expand("%:p")')" = $parent/a.ts
check "project nvim pane gets the focus" grep -q -- "rex focus -s s1 b-app-link" $STUB_LOG
check "project file never opens a tab" test -z "$(grep 'rex \(new\|run\)' $STUB_LOG)"

# nvim in another tab of its session: the app is shown that tab.
print -r -- '{"active_window_id":"window:other","windows":[{"window_id":"window:other","layers":[{"blocks":[{"block_id":"b-x"}]}]},{"window_id":"window:nv","layers":[{"blocks":[{"block_id":"b-y"},{"block_id":"b-app-link"}]}]}]}' > $STUB_FIX/windows-s1.json
: > $STUB_LOG
rex_nvim_open $parent/a.ts
check "the app is shown the project nvim's tab" grep -q -- "rex do -C client:app session.select session_id=s1 window_id=window:nv" $STUB_LOG
rm $STUB_FIX/windows-s1.json

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
# Still inside its :!sleep 8, about 3 s in.
rex_nvim_ping $reply[4]
check "ping: a busy nvim times out" test $? -eq 142

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
check "the app is shown the new tab" grep -q -- "rex do -C client:app session.select session_id=session:f1 window_id=window:new" $STUB_LOG

# Remote Control off: the file still opens, but the app stays on its session,
# so the refusal must reach the user instead of looking like a dead click.
: > $STUB_LOG
: > $tmp/notify.log
STUB_REFUSE=1 rex_nvim_open $loose/Main.java
check "refused session switch still opens the file" test $? -eq 0
check "refused session switch is reported" grep -q 'did not switch to the file.s session: Rex.app is not accepting actions' $tmp/notify.log
check "refused session switch still brings Rex forward" grep -q -- "open -b com.superlogical.rex" $STUB_LOG

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
check "terminal cwd claims the file for its session" grep -q -- "rex run -s session:p2 -c $proj2 --label util.py --json -- nvim -- $proj2/src/util.py" $STUB_LOG
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
export REX_NVIM_SCOPE_FILE=$tmp/config/rex-nvim/scope
source $REX_NVIM_ROOT/lib/config.zsh

rex_nvim_uti_group yml
check "extensions sharing a type form one group" test "$reply" = "yaml yml"
rex_nvim_uti_group tsx
check "groups follow every type of an extension" test "$reply" = "ts tsx"
rex_nvim_uti_group swift
check "an extension with its own type is a group of one" test "$reply" = swift
rex_nvim_uti_group kt
check "a type that prefixes another is not grouped with it" test "$reply" = kt

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

# --- install scope (lib/config.zsh) --------------------------------------------

rex_nvim_scope_read
check "missing scope file reads as global" test $REPLY = global
rex_nvim_scope_write rex
rex_nvim_scope_read
check "scope round-trips" test $REPLY = rex
check "an unknown scope is not written" test "$(rex_nvim_scope_write nope 2>/dev/null; print $?)" = 64
rex_nvim_scope_read
check "a refused write leaves the scope alone" test $REPLY = rex
print -l '# comment' '' '  bogus' > $REX_NVIM_SCOPE_FILE
check "an unknown scope in the file fails" test "$(rex_nvim_scope_read 2> $tmp/scope.err; print $?)" = 1
check "an unknown scope in the file is reported" grep -q 'unknown scope: bogus' $tmp/scope.err
print '# only a comment' > $REX_NVIM_SCOPE_FILE
check "a scope file without a scope fails" test "$(rex_nvim_scope_read 2>/dev/null; print $?)" = 1
rex_nvim_scope_write rex
chmod 000 $REX_NVIM_SCOPE_FILE
check "an unreadable scope file fails, never reads as global" test "$(rex_nvim_scope_read 2>/dev/null; print "$?:$REPLY")" = "1:"
chmod 644 $REX_NVIM_SCOPE_FILE
rm -f $REX_NVIM_SCOPE_FILE
mkdir $REX_NVIM_SCOPE_FILE
check "a directory at the scope path is not written into" test "$(rex_nvim_scope_write rex 2>/dev/null; print $?)" = 1
check "a directory at the scope path is not read as global" test "$(rex_nvim_scope_read 2>/dev/null; print $?)" = 1
rmdir $REX_NVIM_SCOPE_FILE
# Later sections start from the default scope, as an install that predates it.
rm -f $REX_NVIM_SCOPE_FILE

# --- doctor -------------------------------------------------------------------

# duti stub: -d answers from $STUB_DUTI_SET (types already on NvimOpen),
# -s fails for types in $STUB_DUTI_FAIL and logs the others.
export STUB_DUTI_SET=$tmp/duti.set STUB_DUTI_FAIL=$tmp/duti.fail STUB_DUTI_LOG=$tmp/duti.log
: > $STUB_DUTI_SET; : > $STUB_DUTI_FAIL
cat > $stubs/duti <<'EOF'
#!/bin/zsh
case $1 in
  -d) grep -qx -- $2 $STUB_DUTI_SET && print -r -- it.albz.nvimopen ;;
  -s) grep -qx -- $3 $STUB_DUTI_FAIL && exit 1; print -r -- $3 >> $STUB_DUTI_LOG ;;
esac
exit 0
EOF
chmod +x $stubs/duti
# zsh caches command paths: without a rehash the real duti found earlier
# would keep answering, and could change the user's bindings.
rehash
check "duti is the stub" test "$(whence -p duti)" = $stubs/duti
(( failures )) && { print -u2 "duti stub not in effect: stopping before any install test"; exit 1 }

# fake_app: point REX_NVIM_APP at a scratch app calling this clone, so the
# doctor's app check passes without the real one (types.zsh resets it on
# every source).
fake_app() {
  REX_NVIM_APP=$tmp/NvimOpen.app
  mkdir -p $REX_NVIM_APP/Contents
  [[ -e $REX_NVIM_APP/Contents/Info.plist ]] || {
    plutil -create xml1 $REX_NVIM_APP/Contents/Info.plist
    plutil -insert RexNvimBin -string $REX_NVIM_ROOT/bin/rex-nvim $REX_NVIM_APP/Contents/Info.plist
  }
}

source $REX_NVIM_ROOT/lib/doctor.zsh
fake_app
# Stubs over the system queries: swift and m open in Xcode, the rest in
# NvimOpen; the nvim config loads the plugin unless STUB_PLUGIN says
# otherwise (empty: nvim did not answer).
default_app() {
  case $1 in
    *.swift|*.m) print /Applications/Xcode.app ;;
    rex-nvim://*) print $REX_NVIM_APP ;;
    *://*|*.html) print /Applications/Safari.app ;;
    *) print $REX_NVIM_APP ;;
  esac
}
plugin_loaded() { print -r -- ${STUB_PLUGIN-yes} }
integer all_types=${#REX_NVIM_TYPES}

rex_nvim_keep_write
rex_nvim_doctor > $tmp/doctor.out 2>&1
check "doctor exits 1 on types open elsewhere" test $? -eq 1
check "doctor fails on types open elsewhere" grep -q "FAIL  2 of $all_types types open elsewhere: m -> Xcode, swift -> Xcode" $tmp/doctor.out

rex_nvim_keep_write swift m
rex_nvim_doctor > $tmp/doctor.out 2>&1
check "doctor exits 0 once they are kept (counter reset per run)" test $? -eq 0
check "kept types do not fail" test -z "$(grep 'types open elsewhere' $tmp/doctor.out)"
check "kept types are listed as a choice" grep -q 'ok    kept on purpose: m -> Xcode, swift -> Xcode' $tmp/doctor.out
check "kept types leave the bound count" grep -q "all $(( all_types - 2 )) types open with NvimOpen" $tmp/doctor.out
check "doctor without a terminal prints no escape sequences" test -z "$(grep $'\e' $tmp/doctor.out)"
check "loaded plugin is reported" grep -q 'ok    nvim config loads the rex-nvim plugin' $tmp/doctor.out

STUB_PLUGIN=no rex_nvim_doctor > $tmp/doctor.out 2>&1
check "missing plugin in the config fails" grep -q 'FAIL  nvim config does not load' $tmp/doctor.out
STUB_PLUGIN= rex_nvim_doctor > $tmp/doctor.out 2>&1
check "doctor exits 0 when nvim does not answer" test $? -eq 0
check "nvim that does not answer only warns" grep -q 'warn  could not ask nvim' $tmp/doctor.out

rex_nvim_doctor > $tmp/doctor.out 2>&1
check "app accepting actions is reported" grep -q 'ok    Rex app connected, accepts actions' $tmp/doctor.out
STUB_REFUSE=1 rex_nvim_doctor > $tmp/doctor.out 2>&1
check "doctor exits 1 when the app refuses actions" test $? -eq 1
check "app refusing actions fails with Rex's reason" grep -q 'FAIL  Rex app refuses actions: Rex.app is not accepting actions' $tmp/doctor.out
check "app refusing actions points at Remote Control" grep -q 'Remote Control' $tmp/doctor.out

# Registered nvim: each one is pinged. Registrations with a live pid (the
# suite's own) and a stubbed ping keyed on the server address.
saved_state=$REX_NVIM_STATE
REX_NVIM_STATE=$tmp/doctor-state
mkdir -p $REX_NVIM_STATE
rex_nvim_ping() {
  case $1 in
    *busy*) return 142 ;;
    *dead*) return 1 ;;
  esac
}
print -l $work/up s1 b1 /sock/up > $REX_NVIM_STATE/$$.reg
rex_nvim_doctor > $tmp/doctor.out 2>&1
check "doctor exits 0 when nvim answers" test $? -eq 0
check "answering nvim is ok" grep -q "ok    nvim $$ on $work/up" $tmp/doctor.out
print -l $work/up s1 b1 /sock/busy > $REX_NVIM_STATE/$$.reg
rex_nvim_doctor > $tmp/doctor.out 2>&1
check "doctor exits 0 when nvim is busy" test $? -eq 0
check "busy nvim only warns" grep -q "warn  nvim $$ on $work/up is busy" $tmp/doctor.out
print -l $work/up s1 b1 /sock/dead > $REX_NVIM_STATE/$$.reg
rex_nvim_doctor > $tmp/doctor.out 2>&1
check "doctor exits 1 on an unreachable socket" test $? -eq 1
check "unreachable socket fails with its address" grep -q "FAIL  nvim $$ on $work/up: socket /sock/dead not reachable" $tmp/doctor.out
check "unreachable socket suggests a restart" grep -q 'restart that nvim' $tmp/doctor.out
check "unreachable socket points at --fix" grep -q 'rex-nvim doctor --fix' $tmp/doctor.out
check "without --fix the registration stays" test -e $REX_NVIM_STATE/$$.reg

# --fix removes only the unreachable registration. Another live pid: the
# suite's subshell parent is $$, so use a sleeping child for the second one.
sleep 60 &
alive_pid=$!
print -l $work/busy s1 b2 /sock/busy > $REX_NVIM_STATE/$alive_pid.reg
rex_nvim_doctor --fix > $tmp/doctor.out 2>&1
check "doctor --fix exits 0 once the dead socket is gone" test $? -eq 0
check "doctor --fix removes the unreachable registration" test ! -e $REX_NVIM_STATE/$$.reg
check "doctor --fix reports the removal" grep -q "warn  nvim $$ on $work/up: socket gone, registration removed" $tmp/doctor.out
check "doctor --fix keeps a busy registration" test -e $REX_NVIM_STATE/$alive_pid.reg
print -l $work/up s1 b1 /sock/up > $REX_NVIM_STATE/$$.reg
rex_nvim_doctor --fix > $tmp/doctor.out 2>&1
check "doctor --fix keeps an answering registration" test -e $REX_NVIM_STATE/$$.reg
kill $alive_pid; wait $alive_pid 2>/dev/null
rex_nvim_doctor --bogus > $tmp/doctor.out 2>&1
check "doctor rejects an unknown option" test $? -eq 64
rex_nvim_doctor --fix extra > $tmp/doctor.out 2>&1
check "doctor rejects extra arguments" test $? -eq 64
check "a rejected option runs no check" test -z "$(grep -i 'tools' $tmp/doctor.out)"
rm -rf $REX_NVIM_STATE
REX_NVIM_STATE=$saved_state
source $REX_NVIM_ROOT/lib/registry.zsh

# Rex scope: types open elsewhere are the point; leftovers on NvimOpen warn.
rex_nvim_keep_write swift m
rex_nvim_scope_write rex
rex_nvim_doctor > $tmp/doctor.out 2>&1
check "doctor in the rex scope does not fail on types open elsewhere" test $? -eq 0
check "doctor names the rex scope" grep -q 'ok    scope rex: file types stay on their apps' $tmp/doctor.out
check "doctor warns on types left on NvimOpen" grep -q 'warn  still opening with NvimOpen: c, cjs' $tmp/doctor.out
check "doctor in the rex scope ignores the keep list" test -z "$(grep 'kept on purpose' $tmp/doctor.out)"
check "doctor checks that rex-nvim:// links reach NvimOpen" grep -q 'ok    rex-nvim:// links open with NvimOpen' $tmp/doctor.out
rex_nvim_keep_write
() {
  default_app() { [[ $1 == *.html || $1 == *://* ]] && print /Applications/Safari.app || print /Applications/Xcode.app }
  rex_nvim_doctor > $tmp/doctor.out 2>&1
}
check "no leftover, no warning" test -z "$(grep 'still opening with NvimOpen' $tmp/doctor.out)"
check "rex-nvim:// links elsewhere fail in the rex scope" grep -q 'FAIL  rex-nvim:// links open with Safari' $tmp/doctor.out
print bogus > $REX_NVIM_SCOPE_FILE
rex_nvim_doctor > $tmp/doctor.out 2>&1
check "doctor exits 1 on an unreadable scope" test $? -eq 1
check "doctor names the bad scope" grep -q 'FAIL  .*unknown scope: bogus' $tmp/doctor.out
rm -f $REX_NVIM_SCOPE_FILE

# The real probe, against scratch configs: a plugin flagged after VimEnter
# (as lazy.nvim's VeryLazy loads) counts, and the ShaDa file is not touched.
probecfg=$tmp/probe-xdg
mkdir -p $probecfg/config/late $probecfg/config/bare
print -r -- 'vim.api.nvim_create_autocmd("VimEnter", { callback = function() vim.schedule(function() vim.g.loaded_rex_nvim = true end) end })' > $probecfg/config/late/init.lua
: > $probecfg/config/bare/init.lua
real_probe() { ( source $REX_NVIM_ROOT/lib/probe.zsh; XDG_CONFIG_HOME=$probecfg/config XDG_STATE_HOME=$probecfg/state NVIM_APPNAME=$1 plugin_loaded ) }
check "probe sees a plugin loaded after VimEnter" test "$(real_probe late)" = yes
check "probe reports a config without the plugin" test "$(real_probe bare)" = no
check "probe leaves no ShaDa behind" test -z "$(print -l $probecfg/state/**/*.shada(N))"

# --- install wizard -----------------------------------------------------------

source $REX_NVIM_ROOT/lib/wizard.zsh
fake_app
# wizard.zsh sources probe.zsh and install.zsh again: the stubs go back on
# top. swift and m open in Xcode, kt in Android Studio, yaml/yml in
# TextEdit, ts/tsx in QuickTime (with STUB_MIXED, .ts in NvimOpen through
# the video type), the rest in NvimOpen. The app build is skipped, and
# fails with STUB_BUILD_FAIL.
default_app() {
  case $1 in
    *.swift|*.m) print /Applications/Xcode.app ;;
    *.kt) print "/Applications/Android Studio.app" ;;
    *.yaml|*.yml) print /System/Applications/TextEdit.app ;;
    *.ts) [[ -n ${STUB_MIXED-} ]] && print $REX_NVIM_APP || print "/System/Applications/QuickTime Player.app" ;;
    *.tsx) print "/System/Applications/QuickTime Player.app" ;;
    *) print $REX_NVIM_APP ;;
  esac
}
plugin_loaded() { print -r -- ${STUB_PLUGIN-yes} }
rex_nvim_install_app() { [[ -z ${STUB_BUILD_FAIL-} ]] }

rex_nvim_keep_write
rex_nvim_wizard_rows
check "wizard rows are the groups not on nvim" test "${(j:|:)wizard_exts}" = "kt|m|swift|ts tsx|yaml yml"
check "wizard shows the app opening each today" test "${(j:|:)wizard_now}" = "Android Studio|Xcode|Xcode|QuickTime Player|TextEdit"
check "owning IDEs are kept, the rest goes to nvim" test "${(j:|:)wizard_suggest}" = "keep|keep|keep|nvim|nvim"
check "groups on nvim are counted, not listed" test ${#wizard_on_nvim} -eq $(( all_types - 7 ))
rex_nvim_wizard_table > $tmp/table.out
check "table joins a group on one row" grep -q 'yaml, yml' $tmp/table.out
check "table shows the ts note" grep -q 'opens .ts videos in nvim' $tmp/table.out

rex_nvim_wizard_choose auto
check "auto takes the suggestions" test "$reply" = "kt m swift"
rex_nvim_wizard_choose ask <<< '' > /dev/null
check "Enter accepts the suggestions" test "$reply" = "kt m swift"
print -l p n '' k x k '' | rex_nvim_wizard_choose ask > /dev/null
# A pipeline runs the last command in this shell in zsh, so reply is kept.
check "picking each type overrides suggestions" test "$reply" = "m swift ts tsx"
check "quit leaves the choice undone" test "$(rex_nvim_wizard_choose ask <<< q > /dev/null; print $?)" = 1
check "end of input leaves the choice undone" test "$(rex_nvim_wizard_choose ask < /dev/null > /dev/null; print $?)" = 1

rex_nvim_keep_write swift
rex_nvim_wizard_rows
check "an earlier keep stays suggested" test "${wizard_suggest[3]}" = keep

STUB_MIXED=1 rex_nvim_wizard_rows
check "a group half on nvim is still shown" test "${wizard_exts[4]}" = "ts tsx"
check "a mixed group shows every app" test "${wizard_now[4]}" = "NvimOpen/QuickTime Player"

# Terminal picker: it reads keys from stdin, so they can be piped. Rows:
# kt, m, swift (keep), ts tsx, yaml yml (nvim).
rex_nvim_keep_write
rex_nvim_wizard_rows
pick() { print -rn -- "$1" | rex_nvim_wizard_pick > $tmp/pick.out }
pick $'\n'
check "picker: Enter takes the suggestions" test "$reply" = "kt m swift"
pick $'j \n'
check "picker: j and space toggle the second row" test "$reply" = "kt swift"
pick $'\e[B\e[B\e[B \n'
check "picker: arrows move, a group toggles whole" test "$reply" = "kt m swift ts tsx"
pick $'kk \n'
check "picker: up stops at the first row" test "$reply" = "m swift"
pick $'a\n'
check "picker: a sends every row to nvim" test -z "$reply"
pick $'a s\n'
check "picker: s restores the suggestions" test "$reply" = "kt m swift"
check "picker: q stops" test "$(pick q; print $?)" = 1
check "picker: Esc stops" test "$(pick $'\e'; print $?)" = 1
check "picker: end of input stops" test "$(pick ''; print $?)" = 1
ui_rows=13 pick $'jjjj \n'
check "picker: a short terminal scrolls a window" test "$reply" = "kt m swift yaml yml"
check "picker: the window shows its position" grep -q '3-5 of 5' $tmp/pick.out
check "picker: the final frame counts the choice" grep -q '1 to nvim, 4 kept' $tmp/pick.out

# --- install and wizard: bindings and the keep list -------------------------

# install EXT binds the whole group: ts and tsx kept, tsx asked.
rex_nvim_keep_write ts tsx swift
: > $STUB_DUTI_LOG
rex_nvim_install tsx > /dev/null
check "install EXT binds every type of its group" test "$(sort $STUB_DUTI_LOG | tr '\n' ' ')" = "com.microsoft.typescript public.mpeg-2-transport-stream "
rex_nvim_keep_read
check "install EXT takes the bound group off the keep list" test "$reply" = swift

rex_nvim_keep_write ts tsx swift
print public.mpeg-2-transport-stream > $STUB_DUTI_FAIL
rex_nvim_install tsx > /dev/null 2>&1
check "install EXT reports a failed binding" test $? -eq 1
rex_nvim_keep_read
check "a failed binding keeps its group on the list" test "$reply" = "swift ts tsx"
: > $STUB_DUTI_FAIL

STUB_BUILD_FAIL=1 rex_nvim_install swift > /dev/null 2>&1
rex_nvim_keep_read
check "a failed build leaves the keep list alone" test "$reply" = "swift ts tsx"

rex_nvim_keep_write
STUB_BUILD_FAIL=1 rex_nvim_wizard --yes < /dev/null > /dev/null 2>&1
check "a failed build in the wizard leaves the keep list alone" test ! -s $REX_NVIM_KEEP_FILE -o -z "$(grep -v '^#' $REX_NVIM_KEEP_FILE)"

: > $STUB_DUTI_LOG
rex_nvim_wizard --yes < /dev/null > $tmp/wizard.out 2>&1
check "wizard --yes succeeds" test $? -eq 0
rex_nvim_keep_read
check "wizard --yes keeps the suggestions" test "$reply" = "kt m swift"
check "wizard binds what is not kept" grep -qx public.yaml $STUB_DUTI_LOG
check "wizard does not bind what is kept" test -z "$(grep -x public.swift-source $STUB_DUTI_LOG)"
check "wizard without a terminal prints no escape sequences" test -z "$(grep $'\e' $tmp/wizard.out)"

check "wizard reports Remote Control on" grep -q 'Rex app accepts actions' $tmp/wizard.out
STUB_REFUSE=1 rex_nvim_wizard --yes < /dev/null > $tmp/wizard.out 2>&1
check "Remote Control off does not fail the wizard" test $? -eq 0
check "wizard points at Remote Control when the app refuses actions" grep -q 'turn on Remote Control in Rex Settings' $tmp/wizard.out
STUB_APP= rex_nvim_wizard --yes < /dev/null > $tmp/wizard.out 2>&1
check "wizard without the Rex app still names Remote Control" grep -q 'Rex app not running: .*Remote Control' $tmp/wizard.out
check "wizard --yes without a saved scope is global" test "$(grep -v '^#' $REX_NVIM_SCOPE_FILE)" = global

# --- install scope: wizard and install EXT ----------------------------------

# Line by line and picker, from a saved scope.
rex_nvim_wizard_scope_ask global <<< '' > /dev/null
check "scope question: Enter keeps the saved scope" test $REPLY = global
print -l x r | rex_nvim_wizard_scope_ask global > /dev/null
check "scope question: r picks rex, after an invalid answer" test $REPLY = rex
check "scope question: q stops" test "$(rex_nvim_wizard_scope_ask global <<< q > /dev/null; print $?)" = 1
scope_pick() { print -rn -- "$2" | rex_nvim_wizard_scope_pick $1 > $tmp/scope.out }
scope_pick rex $'\n'
check "scope picker: Enter keeps the saved scope" test $REPLY = rex
scope_pick global $'j\n'
check "scope picker: j moves to rex" test $REPLY = rex
scope_pick rex $'\e[A\n'
check "scope picker: up moves to global" test $REPLY = global
check "scope picker: the final frame names the choice" grep -q 'scope: global' $tmp/scope.out
check "scope picker: q stops" test "$(scope_pick global q; print $?)" = 1

# The rex scope binds nothing and says what a global install left behind.
: > $STUB_DUTI_LOG
rex_nvim_wizard --yes --scope rex < /dev/null > $tmp/wizard.out 2>&1
check "wizard --scope rex succeeds" test $? -eq 0
check "wizard --scope rex binds nothing" test ! -s $STUB_DUTI_LOG
check "wizard --scope rex saves the scope" test "$(rex_nvim_scope_read; print $REPLY)" = rex
check "wizard --scope rex lists the types still on NvimOpen" grep -q 'still opening with NvimOpen from a global install: c, cjs' $tmp/wizard.out
check "wizard --scope rex still offers the plugin and checks Rex" grep -q 'Rex app accepts actions' $tmp/wizard.out
rex_nvim_wizard --yes < /dev/null > $tmp/wizard.out 2>&1
check "wizard --yes keeps a saved rex scope" test ! -s $STUB_DUTI_LOG
STUB_BUILD_FAIL=1 rex_nvim_wizard --yes --scope global < /dev/null > /dev/null 2>&1
check "a failed build leaves the scope alone" test "$(rex_nvim_scope_read; print $REPLY)" = rex

check "install EXT refuses in the rex scope" test "$(rex_nvim_install swift 2>&1 >/dev/null; print $?)" = "rex-nvim: the scope is rex, so no file type is bound; to bind them: rex-nvim install --scope global
1"
check "install EXT in the rex scope binds nothing" test ! -s $STUB_DUTI_LOG

rex_nvim_wizard --yes --scope global < /dev/null > /dev/null 2>&1
check "wizard --scope global binds again" grep -qx public.yaml $STUB_DUTI_LOG
check "wizard --scope global saves the scope" test "$(rex_nvim_scope_read; print $REPLY)" = global
check "an empty scope is a usage error, not the saved one" test "$(rex_nvim_wizard --yes --scope '' < /dev/null 2>/dev/null; print $?)" = 64
check "an empty --scope= is a usage error" test "$(rex_nvim_wizard --yes --scope= < /dev/null 2>/dev/null; print $?)" = 64
print bogus > $REX_NVIM_SCOPE_FILE
: > $STUB_DUTI_LOG
check "wizard stops on a bad scope file" test "$(rex_nvim_wizard --yes < /dev/null 2>/dev/null >/dev/null; print $?)" = 1
check "install EXT stops on a bad scope file" test "$(rex_nvim_install swift 2>/dev/null >/dev/null; print $?)" = 1
check "a bad scope file binds nothing" test ! -s $STUB_DUTI_LOG
check "an unknown scope is a usage error" test "$(rex_nvim_wizard --yes --scope nope < /dev/null 2>/dev/null; print $?)" = 64
check "an unknown option is a usage error" test "$(rex_nvim_wizard --nope < /dev/null 2>/dev/null; print $?)" = 64
check "--scope needs a value" test "$(rex_nvim_wizard --scope < /dev/null 2>/dev/null; print $?)" = 64
rm -f $REX_NVIM_SCOPE_FILE

# The real build (osacompile into scratch, never registered): the rex scope
# app declares no file type, not even the applet's default "*".
mkdir -p $tmp/build-rex $tmp/build-global
rex_nvim_build_app $tmp/build-rex/NvimOpen.app rex 2>/dev/null
check "rex build: the app is built" test -r $tmp/build-rex/NvimOpen.app/Contents/Info.plist
check "rex build: no document types declared" test -z "$(plutil -extract CFBundleDocumentTypes raw -o - $tmp/build-rex/NvimOpen.app/Contents/Info.plist 2>/dev/null)"
check "rex build: the rex-nvim scheme is kept" grep -q '<string>rex-nvim</string>' $tmp/build-rex/NvimOpen.app/Contents/Info.plist
rex_nvim_build_app $tmp/build-global/NvimOpen.app 2>/dev/null
check "global build: exact types declared" test "$(plutil -extract CFBundleDocumentTypes.0.LSHandlerRank raw -o - $tmp/build-global/NvimOpen.app/Contents/Info.plist)" = Alternate

# An empty PATH, not one without the stubs: that would find the real duti.
mkdir -p $tmp/empty-path
( PATH=$tmp/empty-path; rex_nvim_wizard --yes < /dev/null > /dev/null 2>&1 )
check "missing duti stops the wizard first" test $? -eq 69

# Keep list behind a symlink, and an unchanged list, are left in place.
mkdir -p $tmp/dot
print -l '# mine' swift > $tmp/dot/keep
saved_keep=$REX_NVIM_KEEP_FILE
REX_NVIM_KEEP_FILE=$tmp/config/linked-keep
ln -s $tmp/dot/keep $REX_NVIM_KEEP_FILE
rex_nvim_keep_write swift
check "an unchanged list keeps the user's comments" grep -qx '# mine' $tmp/dot/keep
rex_nvim_keep_write swift m
check "a symlinked keep list stays a symlink" test -L $REX_NVIM_KEEP_FILE
check "a symlinked keep list is written through" grep -qx m $tmp/dot/keep
REX_NVIM_KEEP_FILE=$saved_keep

# Plugin step against a scratch nvim config.
export XDG_CONFIG_HOME=$tmp/xdg/config XDG_DATA_HOME=$tmp/xdg/data
lazycfg=$XDG_CONFIG_HOME/nvim
mkdir -p $lazycfg/lua/plugins
print -r -- 'require("lazy").setup({ { import = "plugins" } })' > $lazycfg/init.lua
spec=$lazycfg/lua/plugins/rex-nvim.lua

STUB_PLUGIN=yes rex_nvim_wizard_plugin ask > $tmp/plugin.out < /dev/null
check "loaded plugin needs no step" grep -q 'already loads' $tmp/plugin.out
STUB_PLUGIN=no rex_nvim_wizard_plugin auto > $tmp/plugin.out
check "auto only suggests the spec" test ! -e $spec
check "auto names the spec file" grep -q "to load the nvim plugin: write the lazy.nvim spec $spec" $tmp/plugin.out
STUB_PLUGIN=no rex_nvim_wizard_plugin ask <<< n > /dev/null
check "a no leaves the config alone" test ! -e $spec
STUB_PLUGIN=no rex_nvim_wizard_plugin ask <<< y > /dev/null
check "a yes writes the lazy.nvim spec" grep -q "local dir = \[==\[$REX_NVIM_ROOT/nvim\]==\]" $spec
check "the spec is valid Lua returning a spec" test "$($real_nvim --headless --clean -l /dev/stdin <<< "io.write(dofile([[$spec]])[1].name)" 2>&1)" = rex-nvim
print -r -- '-- mine' > $spec
check "writing the spec leaves no temporary file" test "$(print -l $lazycfg/lua/plugins/.*(N))" = ""
STUB_PLUGIN=no rex_nvim_wizard_plugin ask <<< y > $tmp/plugin.out
check "an existing spec is never overwritten" test "$(<$spec)" = '-- mine'
rm $spec
STUB_PLUGIN= rex_nvim_wizard_plugin ask <<< y > $tmp/plugin.out
check "no answer from nvim offers no config change" test ! -e $spec

# A config directory that is a symlink (into a dotfiles repo) is still seen
# as lazy.nvim.
mkdir -p $tmp/dotnvim/lua/plugins
cp $lazycfg/init.lua $tmp/dotnvim/init.lua
mkdir -p $XDG_CONFIG_HOME
ln -s $tmp/dotnvim $XDG_CONFIG_HOME/linked
NVIM_APPNAME=linked STUB_PLUGIN=no rex_nvim_wizard_plugin ask <<< y > /dev/null
check "a symlinked lazy.nvim config gets the spec" test -e $tmp/dotnvim/lua/plugins/rex-nvim.lua
check "a symlinked lazy.nvim config gets no pack link" test ! -e $XDG_DATA_HOME/linked/site/pack/rex-nvim/start/rex-nvim

rm -rf $lazycfg/lua/plugins
STUB_PLUGIN=no rex_nvim_wizard_plugin ask <<< y > $tmp/plugin.out
check "lazy without lua/plugins gets the README" grep -q 'add the spec from the README' $tmp/plugin.out

mkdir -p $XDG_CONFIG_HOME/plain
print -r -- 'vim.o.number = true' > $XDG_CONFIG_HOME/plain/init.lua
NVIM_APPNAME=plain STUB_PLUGIN=no rex_nvim_wizard_plugin ask <<< y > /dev/null
pack=$XDG_DATA_HOME/plain/site/pack/rex-nvim/start/rex-nvim
check "a plain config gets the pack symlink" test "${pack:A}" = ${REX_NVIM_ROOT:A}/nvim
unset XDG_CONFIG_HOME XDG_DATA_HOME

print "$passes passed, $failures failed"
(( failures == 0 ))
