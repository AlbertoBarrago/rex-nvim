# Helpers around the Rex CLI: the app client, sessions and terminal cwds.

# Bundle id of Rex.app, used to launch or bring it to the front.
REX_NVIM_APP_BUNDLE_ID=com.superlogical.rex

# rex_app_client: print the id of the connected Rex app client, if any.
rex_app_client() {
  rex client ls --json 2>/dev/null | jq -r \
    '[.clients[] | select(.info.kind=="app" and .connection_state=="connected")][0].client_id // empty'
}

# rex_ensure_app: print the app client id, launching Rex.app when no app is
# connected. A file opened with no app attached would land in a session
# nobody sees (the server autostarts on its own), so this fails loudly.
rex_ensure_app() {
  local app
  app=$(rex_app_client)
  if [[ -z $app ]]; then
    open -g -b $REX_NVIM_APP_BUNDLE_ID 2>/dev/null || return 1
    repeat 50; do
      app=$(rex_app_client)
      [[ -n $app ]] && break
      sleep 0.1
    done
  fi
  [[ -n $app ]] && print -r -- $app
}

# rex_app_accepts_actions APP: succeed when the Rex app performs actions sent
# from the CLI. With Remote Control off (Rex Settings, Rex Server) it refuses
# them all; REPLY is then Rex's error. client.update.status only reports, so
# probing with it changes nothing on screen.
rex_app_accepts_actions() {
  REPLY=$(rex do -C $1 client.update.status 2>&1 >/dev/null) && return 0
  REPLY=${${REPLY#Error: }:-rex do failed}
  return 1
}

# rex_show_session APP SESSION: make the Rex app show SESSION and come to the
# front. Rex's own focus commands move focus inside a session only; the app
# keeps showing whatever session it was on. A refused session.select is
# reported: the file did open, but in a session the user is not looking at.
rex_show_session() {
  [[ -n $1 && -n $2 ]] || return 1
  local err
  integer rc=0
  if ! err=$(rex do -C $1 session.select session_id=$2 2>&1 >/dev/null); then
    notify "Rex did not switch to the file's session: ${${err#Error: }:-rex do failed}"
    rc=1
  fi
  open -b $REX_NVIM_APP_BUNDLE_ID 2>/dev/null
  return rc
}

# rex_session_by_label LABEL: print the id of the first session with LABEL.
rex_session_by_label() {
  rex ls --json | jq -r --arg l $1 '[.sessions[] | select(.label==$l)][0].session_id // empty'
}

# rex_file_url_path URL: print the local path of a file:// URL (any host),
# percent-decoded and with symlinks resolved.
rex_file_url_path() {
  local p=${1#file://}
  [[ $p == /* ]] || p=/${p#*/}
  printf -v p '%b' ${p//\%/\\x}
  print -r -- ${p:A}
}

# rex_cwd_session FILE [EXCLUDE_SESSION]: set reply=(SESSION DIR) for the
# terminal whose working directory is the deepest ancestor of FILE, scanning
# every session except EXCLUDE_SESSION. Fails when none matches. Each block
# reports the cwd its shell last announced (OSC 7), so idle shells count.
# A shell sitting in $HOME or above would claim every file: those are skipped.
rex_cwd_session() {
  local file=$1 exclude=${2:-} sid bid url dir best_sid best_dir
  integer best_len=0
  for sid in ${(f)"$(rex ls --json | jq -r '.sessions[].session_id')"}; do
    [[ $sid == $exclude ]] && continue
    for bid in ${(f)"$(rex block ls -s $sid --json | jq -r '.blocks[] | select(.flavor|startswith("com.superlogical.terminal")) | .block_id')"}; do
      url=$(rex block call -s $sid -b $bid pwd 2>/dev/null | jq -r '.pwd // empty')
      [[ -n $url ]] || continue
      dir=$(rex_file_url_path $url)
      [[ $dir != / && $dir != ${HOME:A} && ${HOME:A} != $dir/* ]] || continue
      [[ $file == $dir/* ]] || continue
      (( ${#dir} > best_len )) || continue
      best_sid=$sid best_dir=$dir best_len=${#dir}
    done
  done
  [[ -n $best_sid ]] || return 1
  reply=($best_sid $best_dir)
}
