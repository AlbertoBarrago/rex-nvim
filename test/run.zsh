#!/bin/zsh
# test/run.zsh: tests for rex-nvim's registry, `edit` and `open`.
#
# Registry tests run real headless nvim servers. `edit` and `open` run against
# stub `nvim`/`rex`/`glow` commands that log their arguments, so the tests
# never touch the user's Rex sessions or LaunchServices.
# Usage: zsh test/run.zsh

emulate -R zsh
setopt null_glob pipe_fail

REX_NVIM_ROOT=${0:A:h:h}
real_nvim=$(command -v nvim) || { print -u2 "tests need nvim"; exit 1 }

# Short scratch path: nvim sockets live under it too (104-byte sun_path).
tmp=$(mktemp -d /tmp/rex-nvim-test.XXXXXX)
typeset -a server_pids
cleanup() {
  (( ${#server_pids} )) && kill $server_pids 2>/dev/null
  rm -rf $tmp
}
trap cleanup EXIT

export REX_NVIM_STATE_DIR=$tmp/state
mkdir -p $REX_NVIM_STATE_DIR
source $REX_NVIM_ROOT/lib/common.zsh
source $REX_NVIM_ROOT/lib/registry.zsh
source $REX_NVIM_ROOT/lib/open.zsh
source $REX_NVIM_ROOT/lib/edit.zsh
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

# serve ROOT: start a headless nvim registered for ROOT (session s1, block b-ROOT).
serve() {
  local root=${1:A}
  rex_nvim_paths $root
  $real_nvim --headless --clean --listen $reply[1] >/dev/null 2>&1 &
  server_pids+=($!)
  print -rl -- $root s1 "b-${root:t}" > $reply[2]
  repeat 50; do [[ -S $reply[1] ]] && return; sleep 0.1; done
  print -u2 "serve: nvim did not start for $root"
  return 1
}

# --- registry ---------------------------------------------------------------

rex_nvim_paths "/a/very/long/${(l:200::x:)}/project"
check "socket path stays under sun_path limit" test ${#reply[1]} -lt 104
check "socket and block share a name" test ${reply[1]:r} = ${reply[2]:r}

parent=$tmp/work/app
child=$parent/packages/ui
spaced="$tmp/work/my project"
mkdir -p $child "$spaced" $tmp/work/application
for f in $parent/a.ts $child/b.ts "$spaced/c d.ts" $tmp/work/application/x.ts; do : > $f; done
serve $parent && serve $child && serve "$spaced"

found=$(rex_nvim_find ${parent:A}/a.ts)
check "file goes to its project's nvim" test "$(sed -n 1p $found 2>/dev/null)" = ${parent:A}
found=$(rex_nvim_find ${child:A}/b.ts)
check "deepest project wins" test "$(sed -n 1p $found 2>/dev/null)" = ${child:A}
found=$(rex_nvim_find "${spaced:A}/c d.ts")
check "paths with spaces match" test "$(sed -n 1p $found 2>/dev/null)" = "${spaced:A}"
found=$(rex_nvim_find ${tmp:A}/work/application/x.ts)
check "sibling sharing a name prefix does not match" test -z "$found"

orphan_root=$tmp/work/gone
mkdir -p $orphan_root
rex_nvim_paths ${orphan_root:A}
print -rl -- ${orphan_root:A} s1 b-gone > $reply[2]
orphan_blk=$reply[2]
found=$(rex_nvim_find ${orphan_root:A}/z.ts)
check "orphan registration is ignored" test -z "$found"
check "orphan registration is removed" test ! -e $orphan_blk

# --- stubs ------------------------------------------------------------------

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
# The nvim stub records the .block file while running, as `edit` sees it.
cat > $stubs/nvim <<'EOF'
#!/bin/zsh
print -r -- "nvim $*" >> $STUB_LOG
[[ -n ${STUB_BLOCKS_DIR:-} ]] && cat $STUB_BLOCKS_DIR/*.block >> $STUB_LOG 2>/dev/null
[[ -n ${STUB_TAKEOVER:-} ]] && sed -i '' '3s/.*/b-other/' $STUB_BLOCKS_DIR/*.block
exit 0
EOF
chmod +x $stubs/*
export STUB_LOG=$tmp/stub.log

# --- edit -------------------------------------------------------------------

proj=$tmp/edit/proj
mkdir -p $proj
(
  export PATH=$stubs:$PATH REX_NVIM_STATE_DIR=$tmp/edit-state STUB_BLOCKS_DIR=$tmp/edit-state
  REX_NVIM_STATE=$REX_NVIM_STATE_DIR REX_SESSION=s9 REX_BLOCK=b9
  : > $STUB_LOG
  rex_nvim_edit $proj
)
check "edit starts nvim listening on the project socket" grep -q -- '--listen .*\.sock \.$' $STUB_LOG
check "edit registers root, session and block" grep -qx -- "b9" $STUB_LOG
check "edit registration holds the physical root" grep -qx -- ${proj:A} $STUB_LOG
check "edit removes its registration on exit" test -z "$(print $tmp/edit-state/*.block)"

(
  export PATH=$stubs:$PATH REX_NVIM_STATE_DIR=$tmp/edit-state STUB_BLOCKS_DIR=$tmp/edit-state STUB_TAKEOVER=1
  REX_NVIM_STATE=$REX_NVIM_STATE_DIR REX_SESSION=s9 REX_BLOCK=b9
  rex_nvim_edit $proj
)
check "edit keeps a registration another pane took over" test -n "$(print $tmp/edit-state/*.block)"

(
  export PATH=$stubs:$PATH
  unset REX_BLOCK
  : > $STUB_LOG
  rex_nvim_edit $proj
)
check "edit outside Rex runs plain nvim" grep -qx -- 'nvim .' $STUB_LOG

# --- open -------------------------------------------------------------------

loose=$tmp/loose
mkdir -p $loose
: > $loose/notes.md
: > $loose/Main.java

(
  export PATH=$stubs:$PATH
  : > $STUB_LOG
  rex_nvim_open $loose/notes.md $loose/Main.java
)
check "markdown opens in glow" grep -q -- "rex new files .*-- glow -p ${loose:A}/notes.md" $STUB_LOG
check "other files open in nvim" grep -q -- "rex new files .*-- nvim -- ${loose:A}/Main.java" $STUB_LOG

(
  export PATH=$stubs:$PATH STUB_SESSIONS='{"sessions":[{"session_id":"session:f1","label":"files"}]}'
  : > $STUB_LOG
  rex_nvim_open $loose/Main.java
)
check "existing files session is reused" grep -q -- "rex run -s session:f1 .*-- nvim -- ${loose:A}/Main.java" $STUB_LOG

(
  : > $STUB_LOG
  rex_nvim_open ${parent:A}/a.ts
)
check "project file never opens a files tab" test -z "$(grep 'rex \(new\|run\)' $STUB_LOG)"
check "project file loads in the project's nvim" test "$($real_nvim --server ${$(rex_nvim_find ${parent:A}/a.ts):r}.sock --remote-expr 'bufname()' 2>/dev/null)" = ${parent:A}/a.ts

print "$passes passed, $failures failed"
(( failures == 0 ))
