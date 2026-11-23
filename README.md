# rex-nvim

nvim integration for the [Rex](https://www.superlogical.com/rex) terminal on macOS: clicking a file hyperlink (or double-clicking a code file in Finder) opens it in nvim inside Rex instead of a GUI editor.

- A file inside the working directory of an nvim running in a Rex pane loads in that nvim, and Rex focuses its pane.
- Any other file opens as a new tab of the Rex session `files`, created on first use: in nvim, or in [glow](https://github.com/charmbracelet/glow) for Markdown (read-only, `q` closes it). The tab closes when the program exits.

## Install

```sh
brew install neovim duti jq glow
git clone https://github.com/AlbertoBarrago/rex-nvim.git ~/Projects/rex-nvim
~/Projects/rex-nvim/install.sh     # links rex-nvim into ~/.local/bin
rex-nvim install                   # builds NvimOpen.app, binds file types
duti -x html                       # must still be your browser
```

macOS asks to confirm each newly bound file type (about 30 dialogs on a fresh machine, none on a rerun): confirm only the ones that name NvimOpen. `rex-nvim install EXT...` binds only the given extensions, handy to add one later.

Then load the nvim plugin, so every nvim started in a Rex pane registers itself. With lazy.nvim, add a spec (for example `lua/plugins/rex-nvim.lua`):

```lua
local dir = vim.fn.expand("~/Projects/rex-nvim/nvim")
return {
  { dir = dir, name = "rex-nvim", lazy = false, cond = vim.uv.fs_stat(dir) ~= nil },
}
```

Without a plugin manager, `vim.opt.rtp:append(vim.fn.expand("~/Projects/rex-nvim/nvim"))` in `init.lua` does the same. `rex-nvim edit` loads the plugin even when the config does not.

`glow` is optional: without it Markdown opens in nvim too.

## Commands

| Command | What it does |
| --- | --- |
| `rex-nvim open FILE[:LINE[:COL]]...` | Open files as described above. This is what NvimOpen.app runs. |
| `rex-nvim edit [DIR]` | Start nvim in `DIR` (default `.`) with the plugin loaded. |
| `rex-nvim install [EXT...]` | Build `~/Applications/NvimOpen.app` and make it the default app for the supported file types. |

## How it works

```
click on a file link
  -> macOS LaunchServices -> NvimOpen.app (default app for the file type)
  -> rex-nvim open FILE
       registered nvim whose working directory holds FILE?
         yes -> rex focus its pane, then open FILE through the plugin (3 s timeout)
         no, or nvim busy -> new tab in Rex session "files"
```

- **Registry.** The plugin (`nvim/`) runs in every nvim with `$REX_BLOCK` set, that is inside a Rex pane. It writes `~/.cache/rex-nvim/<pid>.reg` with the physical working directory, the Rex session and block, and nvim's RPC address; it refreshes it on `:cd` and when the pane gains focus, and removes it on exit. `open` drops registrations whose process is gone. The deepest matching directory wins; among nvim on the same one, the most recently focused.
- **Opening.** `open` calls the plugin's `open()` over RPC rather than `--remote`: it picks a regular window (never a `winfixbuf` sidebar, a floating or special window), leaves insert mode, does not stop on an existing swap file, and moves the cursor to `LINE:COL`. A busy nvim (for example running `:!npm test`) answers only when done, so after 3 seconds the file opens in a tab instead.
- **Why a fixed `files` session.** The Rex server does not know which session the app is showing, and `rex run` refuses to guess when several exist. A dedicated session keeps the target predictable.
- **File types.** NvimOpen binds exact content types (UTIs), never generic ones such as `public.data`: declaring those makes macOS offer the app for every file. `html` is left out on purpose, since binding `public.html` makes the app the default web browser. `.plist` stays with Xcode (macOS types binary plists the same way). macOS types `.ts` as MPEG-2 video first, so that video type is bound too and `.ts` videos open in nvim. Extensions macOS has no type for (`.jsx`, `.lua`, `.rs`, `.go`, `.kt`) get a type declared by NvimOpen.

## Known limits

- Clicked links open the file, not the line: macOS hands the app a file URL without the `:line` part. `rex-nvim open FILE:LINE` from a shell does jump.
- An nvim without the plugin loaded does not receive files.

## Tests

```sh
zsh test/run.zsh
```

The suite starts real headless nvim instances with the plugin loaded; `rex` and `glow` are stubs that come first in `PATH`, so it never touches your Rex sessions or LaunchServices.

## License

MIT
