# Review guide: rex-nvim

Check only the rules whose trigger matches a path in the diff. For each finding, name the rule (R1, R2, ...) or say "outside REVIEW.md" when it is a bug no rule covers. Report real defects with a concrete failure scenario; skip anything listed under "Do not flag".

## Rules

### R1: Empty fields survive array copies and arguments
Trigger: `lib/*.zsh`, `bin/rex-nvim`
Check: an array that can hold empty elements (a registration read by `rex_nvim_read_reg`, `reply` from any helper) is copied quoted (`("${reply[@]}")`), and its elements are passed quoted (`"$meta[2]"`) to commands and functions whose argument positions matter.
Why: zsh drops empty unquoted words. With `$REX_SESSION` empty, `meta=($reply)` shifted the RPC address, `nvim --server --remote-expr EXPR` opened EXPR as a file and timed out, and every registered nvim looked busy. (fixes: 33aa9c6)

### R2: zsh expansion forms that silently misbehave
Trigger: `lib/*.zsh`
Check: no history modifiers combined with a default in one expansion (`${x:t:r:-none}`, use `${${x:t:r}:-none}`); `(Ie)` and other subscript flags applied to arrays, not one-word scalars; nested set operations such as `${#${a:*b}}` checked to expand to what is meant.
Why: zsh rejected `${got:t:r:-none}` and doctor aborted; `(Ie)` on a scalar matched substrings and grouped `kt` with `kts`; `${#${a:*b}}` always expanded to nothing, so no type ever left the keep list. (fixes: 6a3a0e8, b5f1896, adbffe4)

### R3: Rex actions report their failure
Trigger: `lib/rex.zsh`, `lib/open.zsh`, `lib/doctor.zsh`
Check: a `rex do` / `rex run` / `rex focus` whose failure changes what the user sees is checked, and the failure reaches the user (notify and log, or a doctor line) with Rex's reason; output is not sent to `/dev/null` without that.
Why: with Remote Control off, `session.select` failed silently and a Finder double-click opened the file in a session Rex was not showing. (fixes: ea2d2f8)

### R4: Calls to nvim never hang a click
Trigger: `lib/open.zsh`, `lib/registry.zsh`, `lib/doctor.zsh`, `lib/probe.zsh`
Check: every `nvim --server ... --remote-*` and every headless nvim probe runs under `with_timeout`, and the timeout status (142) is handled as "busy", not as success or a generic failure.
Why: an nvim blocked in `:!cmd` answers RPC only when done; the click must fall through to the next target. (source: CLAUDE.md, Architecture)

### R5: LaunchServices bindings stay narrow
Trigger: `lib/types.zsh`, `lib/install.zsh`, `lib/wizard.zsh`, `macos/*`
Check: only exact per-extension UTIs are bound, never `public.data`, `public.text`, `public.item`, `public.html`, `http` or `https`; a type is bound only after a `duti -d` check shows it is not already bound; `duti -s` is never looped over the whole list; `REX_NVIM_BUNDLE_ID` is unchanged; the app is built in a scratch dir and swapped in complete.
Why: each change shows a macOS dialog; generic types make NvimOpen the handler for every file, `public.html` makes it the default browser, a new bundle id orphans every binding. (source: CLAUDE.md, LaunchServices rules)

### R6: Both sides agree on paths and state
Trigger: `nvim/**`, `lib/registry.zsh`, `lib/open.zsh`, `lib/common.zsh`
Check: paths compared between plugin and shell are physical (symlinks resolved on both sides); `REX_NVIM_STATE_DIR` is used for tests only; `lib/common.zsh` appends to `PATH`, never prepends.
Why: NvimOpen.app runs with LaunchServices' bare environment, and a prepended PATH gives nvim started by `edit` a different node/python than the shell. (source: CLAUDE.md, Architecture)

### R7: User files are written safely
Trigger: `lib/config.zsh`, `lib/wizard.zsh`, `nvim/lua/rex-nvim/registry.lua`
Check: files the user owns (nvim config spec, keep list, scope file) are never overwritten when they already exist with other content, are written through a symlink to the real file, and are written via a temporary file moved or linked into place; the registry file is written atomically.
Why: the lazy.nvim spec could overwrite the user's own file, and a symlinked keep list (dotfiles) was replaced by a plain file. (fixes: adbffe4)

### R8: Tests never touch the real system
Trigger: `test/run.zsh`
Check: `rex`, `duti`, `glow` and `open` are stubs first in `PATH` (with `rehash` after creating a stub); fixtures and helper redefinitions are removed or restored before later sections rely on them; nvim processes started by a test are killed by the pid it started; nothing closes Rex blocks or nvim by a broad filter.
Why: a cached path to the real `duti` could have changed the user's bindings, and broad cleanup would kill the user's own nvim. (fixes: adbffe4 | source: CLAUDE.md, Testing against the real app)

## Do not flag

- Shell style and quoting that zsh handles safely (unquoted scalars that cannot be empty, `[[ ]]` operands): there is no linter, `zsh -n` is the only syntax gate.
- The `rex` CLI being called several times per `open`: Rex has no batch query, and the constraints in CLAUDE.md ("Rex constraints") explain why targets are derived this way.
