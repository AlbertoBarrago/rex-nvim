# rex-nvim

nvim integration for the [Rex](https://www.superlogical.com/rex) terminal on macOS: clicking a file hyperlink (or double-clicking a code file in Finder) opens it in nvim inside Rex instead of a GUI editor.

- A file inside a project that has an nvim running (started with `rex-nvim edit`) loads in that nvim, and Rex focuses its pane.
- Any other file opens as a new tab of the Rex session `files`, created on first use: in nvim, or in [glow](https://github.com/charmbracelet/glow) for Markdown (read-only, `q` closes it). The tab closes when the program exits.

## Install

```sh
brew install neovim duti jq glow
git clone git@github.com:AlbertoBarrago/rex-nvim.git ~/Projects/rex-nvim
~/Projects/rex-nvim/install.sh     # links rex-nvim into ~/.local/bin
rex-nvim install                   # builds NvimOpen.app, binds file types
duti -x html                       # must still be your browser
```

macOS asks to confirm each newly bound file type (about 30 dialogs on a fresh machine, none on a rerun): confirm only the ones that name NvimOpen. `rex-nvim install EXT...` binds only the given extensions, handy to add one later.

`glow` is optional: without it Markdown opens in nvim too.

## Commands

| Command | What it does |
| --- | --- |
| `rex-nvim edit [DIR]` | Start nvim in `DIR` (default `.`) and register it for that project. Outside Rex it is plain nvim. |
| `rex-nvim open FILE...` | Open files as described above. This is what NvimOpen.app runs. |
| `rex-nvim install [EXT...]` | Build `~/Applications/NvimOpen.app` and make it the default app for the supported file types. |

To route links to your editor pane, start nvim with `rex-nvim edit` instead of `nvim`, for example from a shell function that lays out your Rex panes.

## How it works

```
click on a file link
  -> macOS LaunchServices -> NvimOpen.app (default app for the file type)
  -> rex-nvim open FILE
       registered nvim whose project holds FILE?  yes -> nvim --remote FILE, rex focus its pane
                                                   no  -> new tab in Rex session "files"
```

- **Registry.** `rex-nvim edit` makes nvim listen on `~/.cache/rex-nvim/<hash>.sock`, where `<hash>` is a short sha256 of the project's physical root (symlinks resolved), so the socket path stays under macOS's 104-byte limit. `<hash>.block` beside it holds the root, the Rex session and the Rex block. Both are removed when that nvim exits, unless another pane took the project over. When several projects match, the deepest root wins.
- **Why a fixed `files` session.** The Rex server does not know which session the app is showing, and `rex run` refuses to guess when several exist. A dedicated session keeps the target predictable.
- **File types.** NvimOpen binds exact content types (UTIs), never generic ones such as `public.data`: declaring those makes macOS offer the app for every file. `html` is left out on purpose, since binding `public.html` makes the app the default web browser. `.plist` stays with Xcode (macOS types binary plists the same way). macOS types `.ts` as MPEG-2 video first, so that video type is bound too and `.ts` videos open in nvim. Extensions macOS has no type for (`.jsx`, `.lua`, `.rs`, `.go`, `.kt`) get a type declared by NvimOpen.

## Known limits

- Links open the file, not the line: macOS hands the app a file URL without the `:line` part.
- Only nvim instances started with `rex-nvim edit` receive files.

## Tests

```sh
zsh test/run.zsh
```

Registry tests run real headless nvim servers; `edit` and `open` run against stub `nvim`, `rex` and `glow` commands, so the suite never touches your Rex sessions or LaunchServices.

## License

MIT
