# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

macOS-only nvim integration for the Rex terminal: a zsh CLI plus a small nvim Lua plugin (no build step, no runtime dependencies beyond nvim, jq, perl, duti and optionally glow). `bin/rex-nvim` dispatches to `lib/*.zsh`; `nvim/` is the plugin (loaded by the user's nvim config); `NvimOpen.app` is an AppleScript applet compiled from `macos/NvimOpen.applescript` that LaunchServices uses as the default app for code files and that calls `rex-nvim open`.

## Commands

```sh
zsh test/run.zsh                       # full suite (plugin, registry, open, edit), about 5 s
for f in bin/rex-nvim lib/*.zsh test/run.zsh; do zsh -n $f; done; sh -n install.sh   # syntax
./install.sh                           # link bin/rex-nvim into ~/.local/bin
rex-nvim install [EXT...]              # rebuild NvimOpen.app and bind file types
```

There is no single-test runner: `test/run.zsh` is one script of `check NAME COMMAND...` calls. To focus, comment out sections or run it and grep its `FAIL:` lines.

## Architecture

The plugin writes, the shell reads:

- `nvim/plugin/rex-nvim.lua` + `nvim/lua/rex-nvim/registry.lua`: in an nvim with `$REX_BLOCK` set, write `~/.cache/rex-nvim/<pid>.reg` (4 lines: physical `getcwd(-1,-1)`, `$REX_SESSION`, `$REX_BLOCK`, `v:servername`) atomically on VimEnter, refresh on global DirChanged and FocusGained (mtime = recency), remove on VimLeavePre.
- `lib/registry.zsh`: `rex_nvim_live_regs` lists registrations newest first and deletes those whose pid is dead; `rex_nvim_find` picks the deepest root containing the file (ties: newest).
- `lib/open.zsh`: parses `FILE[:LINE[:COL]]` (a name that exists as given is never split), `rex focus`es the registered pane first, then calls `require("rex-nvim").open(path, line, col)` via `--remote-expr luaeval(...)` under `with_timeout` (perl alarm, exit 142). That function (`nvim/lua/rex-nvim/init.lua`) avoids `--remote`'s `:drop`-in-current-window problems: `winfixbuf`, sidebars, swap prompts, insert mode. Any failure or timeout falls through to the next target. Targets, in order (`rex_nvim_route`): the registered nvim; a new nvim tab in the session whose terminal cwd is the deepest ancestor of the file (`rex_cwd_session` in lib/rex.zsh, via the block method `pwd`; cwds at or above `$HOME` ignored); the nvim registered in the `files` session; a new tab there (`rex new files` on first use). Unclaimed Markdown uses `glow -p`. Finally the app client is asked to `session.select` the target and Rex.app is brought forward; with no app connected it is launched (`rex_ensure_app`).
- `lib/edit.zsh`: `exec nvim` with the plugin appended to `rtp`, for configs that do not load it.

Both sides must compare physical paths (symlinks resolved), and both must agree on `REX_NVIM_STATE`: NvimOpen.app runs with LaunchServices' bare environment, never the user's shell profile, so `REX_NVIM_STATE_DIR` is for tests only. `lib/common.zsh` appends fallbacks to `PATH` for the same reason (including the `rex` binary inside the Rex Server bundle, `Versions/Current`); it must append, never prepend, or nvim started by `edit` gets a different node/python than the shell.

## Rex constraints (verified, do not re-try)

- The Rex server cannot tell which session the app is showing (the app is attached to all of them), and `rex run` without `-s` fails with "session target default is ambiguous" when several sessions exist. Hence targets derived from the file (terminal cwds) and the `files` session. The app client action `session.select session_id=...` does switch the app's view.
- `client.tab.new` performed from outside the app creates a **new session** per call and leaves empty sessions behind. `client.perform` cannot run `init.lua` actions on the app ("does not offer"), so a Lua action cannot learn the app's current session either.

## LaunchServices rules (lib/install.zsh)

These come from real incidents; keep them:

- macOS shows a confirmation dialog for every default-handler change. Only bind types not already bound (`duti -d` check), never loop `duti -s`, and probe one type first when changing the list.
- Bind exact UTIs per extension, never generic types (`public.data`, `public.text`, `public.item`), which make macOS offer NvimOpen for every file.
- Never bind `public.html` (or `http`/`https`): it makes NvimOpen the default web browser. After any change, check `duti -x html`.
- Extensions with no system UTI need an entry in `REX_NVIM_IMPORTED`: LaunchServices refuses a handler for a dynamic `dyn.*` type.
- `.ts` is typed `public.mpeg-2-transport-stream` first; that video type is bound on purpose.
- Keep `REX_NVIM_BUNDLE_ID` (`it.albz.nvimopen`): changing it orphans every existing binding and re-triggers all dialogs.
- The app is built in a scratch dir and swapped in only when complete, because bound types would otherwise point at a missing app.
- Verify bindings with what actually opens, not with `duti`'s exit status (a pending dialog reports success): `osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL(\$.NSURL.fileURLWithPath('/path/x.ext')).path.js"`.

## Testing against the real app

End-to-end checks use `open FILE` (LaunchServices) with several Rex sessions open. Tests that create Rex tabs or sessions must close them afterwards (empty sessions are left behind otherwise), by the ids they created: never close blocks by a broad filter or send `:qa!` to every registered nvim, since the user's own nvim registers too. `open` also switches the app's session; select the original one back when done.
