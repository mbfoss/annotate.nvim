# Development

Internals of annotate.nvim: how the modules fit together, and why the parts
that look odd are the way they are. For what the plugin does and how to use it,
see [README.md](README.md).

## Layout

```
plugin/annotate.lua             version guard, lazy :Annotate, first-file hook
lua/annotate/init.lua           :Annotate dispatch, completion, setup()
lua/annotate/config.lua         defaults, and the project root behind the store
lua/annotate/notes.lua          the feature: what a note is, and the commands
lua/annotate/store.lua          per-project JSON persistence
lua/annotate/util/
    extmarks.lua                extmarks keyed by file rather than by buffer
    ui.lua                      cursor location, prompting, jumping to a note
    usercmd.lua                 argument splitting + subcommand completion
```

`init.lua` owns only argument parsing and completion; the feature is
`notes.lua`.

## Loading

Loading is driven from `plugin/annotate.lua`, the only module read at startup.
It registers `:Annotate` through `util/usercmd` — the argument splitter and
completion dispatcher, which knows nothing about the subcommands — passing run
and completion callbacks that are `require("annotate").run` / `.complete`
behind a `require` performed at call time. `init.lua` and the modules it pulls
in are therefore read on the first `:Annotate` invocation (or the first
`<Tab>`), not before.

Registration belongs to `plugin/`, which every loading path reaches — including
`packadd!` during startup, whose bang only suppresses sourcing at that moment
and leaves it to the normal plugin pass. (A `packadd!` issued *after* startup
never sources `plugin/`; use the plain `packadd` there.)

`setup()` exists, but only to change a default; nothing requires it, and it is
not what registers anything. It is also the one call that can arrive *after*
the notes are already on screen, since opening a file is enough to draw them —
so it ends in `notes.refresh()`, which redraws them under the new
configuration. It reaches for that only when `annotate.notes` is already in
`package.loaded`, so a `setup()` in an otherwise untouched session does not
pull the feature modules in by itself.

The one thing that cannot be lazy is a note appearing in a file the user opens
without asking for anything. `plugin/` therefore also registers a single
`BufReadPost` autocommand, `once = true`, which requires `annotate.notes` and
loads it. From then on `util/extmarks` has its own `BufReadPost` and the
bootstrap one is spent. The buffer that triggered it is covered by the sweep
over already-loaded buffers that `define_group` performs, because
`util/extmarks` installs its autocommand *during* that same event and Neovim
does not run autocommands added mid-event.

## Notes are extmarks, but not only extmarks

A note has to survive things an extmark does not. It is restored from disk
before anything is open, it outlives the buffer being unloaded, and it has to
come back on the right line when the file is opened again — while, in between,
it must track the user's edits, which is exactly what an extmark is for and
what a stored line number is not.

`util/extmarks.lua` is that pairing. A group keeps `file -> id -> mark` as the
durable copy and mirrors it into whichever buffers happen to be loaded, so
positions have two sources:

| state | authority |
| --- | --- |
| file loaded in a buffer | the buffer — the extmark has been tracking edits |
| not loaded | the group's own table |

The reads that take a `live` flag (`get_extmark_by_location`, `get_extmarks`,
`get_file_extmarks`) go to `nvim_buf_get_extmarks` when there is a buffer and
report what it says; `notes.lua` passes `live = true` everywhere, so nothing
else has to think about which of the two is current. `BufWritePost` and
`BufUnload` fold the drift back into the table even for notes nobody read,
which is what makes a note written to the store name the line the user just
saved.

Placement is clamped to the buffer's line count: a file can have been shortened
outside the editor since its notes were written, and a stale line number should
be a note at the end rather than an error.

The module is generic and self-contained, so that it can be vendored: it holds
no plugin name of its own, and `M.init(prefix)` is what claims one. Namespaces
and augroups are process-wide and keyed by name, while the group table is per
module instance, so two copies of this file asking for the same group name
would otherwise share a namespace and clear each other's autocommands. That is
also why `M.define_group` hands back a table of closures over one group rather
than a shared module-level API.

`define_group` sweeps the buffers that are already loaded, which is what draws
the notes in the buffer whose `BufReadPost` bootstrapped the plugin — the
module's own `BufReadPost` is registered during that same event and so does not
run for it. `notes.attach()` therefore only has to load.

Drawing options — the virtual text, the highlight, the priority — live on the
mark, not on the group. `notes.refresh()` consequently rebuilds the marks
instead of calling the group's `refresh()`, which would redraw the existing
ones under the configuration they were created with.

## Storage

`store.lua` writes one JSON file per project root under
`stdpath("data")/annotate/`, named `<basename>-<sha256[:12]>.json` — the
basename so the directory can be read by a human, the digest because that is
what actually distinguishes two roots with the same name.

Notes are stored relative to the root when they are under it, absolute when
they are not (a header read out of `/usr/include`), so moving or re-cloning a
project does not orphan them.

Writes go to `<store>.tmp` and are renamed over the store, so a store that
exists is always a complete one: saving happens on `VimLeavePre` among other
places, where a process that goes away mid-write would otherwise leave a
truncated file behind. Clearing the last note removes the store rather than
leaving an empty one.

A store that is missing is a project with no notes. One that is unreadable or
malformed is reported and treated the same way — a corrupt file costs the
session its notes, never its startup.

## The project root

`config.values.root()` answers "which project is this", and the answer is
`git rev-parse --show-toplevel` of the current directory, falling back to the
current directory itself. It is memoised per directory: it is asked on every
note and cannot change while the directory stays put, and it forks `git`.

It is a function in the configuration rather than a fixed value so that a
`rooter`-style setup can hand over its own notion of a project.

`notes.load()` resolves it once, at load, and holds it for the session — the
store a session writes back is the one it read.

## UI

Everything the plugin asks the user goes through `vim.ui.*`: prompting for a
note's text is `vim.ui.input`, picking one is `vim.ui.select`, and confirming a
clear is `vim.ui.select` over yes/no with no as the default, since everything
asked there destroys notes. That way the plugin has no picker of its own to
maintain and inherits whichever one the user has installed.

`ui.open` prefers a window in the current tab that already shows the file,
falls back to editing in the current window, and never opens into a floating
window — a note picked from a float would otherwise replace the float's own
buffer.

## Help file

`doc/annotate.txt` is generated from `README.md`; edit the README, never the
help file. Regenerate with

```sh
scripts/gendoc.sh          # rewrites doc/annotate.txt and doc/tags
scripts/gendoc.sh --check  # exits 1 when the help file is stale
```

The generator is [panvimdoc](https://github.com/kdheepak/panvimdoc), pinned in
`scripts/gendoc.sh` to a commit — a tag can be moved, a commit cannot, so the
same README always produces the same help file. It is fetched into
`$XDG_CACHE_HOME/panvimdoc-<commit>` on first run and reused after that. Set
`PANVIMDOC_DIR` to use a checkout of your own. The only tool you need installed
is `pandoc` (`brew install pandoc`); nvim is used just to refresh `doc/tags`.

`doc/tags` is committed, as |package-create| recommends: nothing in the native
package path generates it, so shipping it is what makes `:help annotate` work
for someone who drops the repo into `pack/*/opt` and runs `packadd`. Plugin
managers — including `vim.pack` — delete and regenerate it on install and
update, so the committed copy costs them nothing.

Section names come from the README headings, and so do the tags. A heading may
end in a hidden comment naming the tag it wants, with the project name prefixed
automatically:

```markdown
## Configuration <!-- tag: configuration -->
```

The comment is invisible on GitHub. Every section in the README declares one,
so that renaming a section never silently renames its help tag.

## Conventions

- User-visible messages go through a module-local `_notify` that prefixes
  `[annotate]`.
- Private functions are `_`-prefixed and file-local; the module table exports
  only entry points.
- Types are declared with LuaLS `---@class` / `---@field` annotations.
- Highlight groups are defined with `default = true` so a colorscheme wins, and
  redefined on `ColorScheme`, which clears them.
- Configuration is read at the point of use. `config.values` is mutated in
  place rather than replaced, so a module that captured it in a local at
  `require` time does not go on reading the pre-`setup()` table.

## History

This plugin started as the notes half of `loop-marks.nvim`, an extension to
[loop.nvim](https://github.com/loop-nvim/loop.nvim). What loop.nvim supplied is
now the plugin's own: workspace persistence became `store.lua`, `loop.extmarks`
became `util/extmarks.lua` with one group instead of a registry, and the
workspace picker, floating input and confirmation became `vim.ui.select` /
`vim.ui.input`. The bookmarks half was dropped.
