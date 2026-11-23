# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

macOS-only nvim integration for the Rex terminal, written in zsh (no build step, no runtime dependencies beyond nvim, jq, duti and optionally glow). `bin/rex-nvim` dispatches to `lib/*.zsh`; `NvimOpen.app` is an AppleScript applet compiled from `macos/NvimOpen.applescript` that LaunchServices uses as the default app for code files and that calls `rex-nvim open`.

## Commands

```sh
zsh test/run.zsh                       # full suite (registry, edit, open)
for f in bin/rex-nvim lib/*.zsh test/run.zsh; do zsh -n $f; done; sh -n install.sh   # syntax
./install.sh                           # link bin/rex-nvim into ~/.local/bin
rex-nvim install [EXT...]              # rebuild NvimOpen.app and bind file types
```

There is no single-test runner: `test/run.zsh` is one script of `check NAME COMMAND...` calls. To focus, comment out sections or run it and grep its `FAIL:` lines.

## Architecture

Two entry points share one registry (`lib/registry.zsh`):

- `rex-nvim edit` (lib/edit.zsh) runs nvim with `--listen ~/.cache/rex-nvim/<hash>.sock` and writes `<hash>.block` (3 lines: physical project root, `$REX_SESSION`, `$REX_BLOCK`). `<hash>` is sha256 of `${PWD:A}` cut to 16 chars, keeping the socket under the 104-byte `sun_path` limit. On exit it removes both files only if line 3 is still its own block (another pane may have taken the project over).
- `rex-nvim open` (lib/open.zsh) resolves each file with `${file:A}`, picks the registered nvim with the deepest matching root (`rex_nvim_find`), sends the file with `nvim --server ... --remote` and `rex focus`es its pane. Unclaimed files go to a new tab of the Rex session labelled `files` (`rex run -s`, or `rex new files` on first use); Markdown uses `glow -p` there.

Both sides must compare physical paths (symlinks resolved), and both must agree on `REX_NVIM_STATE`: NvimOpen.app runs with LaunchServices' bare environment, never the user's shell profile, so `REX_NVIM_STATE_DIR` is for tests only. `lib/common.zsh` rebuilds `PATH` for the same reason, including the `rex` binary inside the Rex Server bundle (`Versions/Current`).

## Rex constraints (verified, do not re-try)

- The Rex server cannot tell which session the app is showing (the app is attached to all of them), and `rex run` without `-s` fails with "session target default is ambiguous" when several sessions exist. Hence the fixed `files` session.
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

End-to-end checks use `open FILE` (LaunchServices) with several Rex sessions open. Tests that create Rex tabs or sessions must close them afterwards; empty sessions are left behind otherwise.
