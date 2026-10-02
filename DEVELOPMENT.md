# Development

Internals of annotate.nvim: how the modules fit together, and why the odd
parts are the way they are. For usage, see [README.md](README.md).

## Layout

```
plugin/annotate.lua             version guard, lazy :Annotate, first-file hook
lua/annotate/init.lua           :Annotate dispatch, completion, setup()
lua/annotate/config.lua         defaults and `setup()`
lua/annotate/notes.lua          the feature: what a note is, and the commands
lua/annotate/store.lua          JSON persistence
lua/annotate/util/
    fileextmarks.lua                extmarks keyed by file rather than by buffer
    ui.lua                      cursor location, prompting, jumping to a note
    usercmd.lua                 argument splitting + subcommand completion
```

`init.lua` owns only argument parsing and completion; the feature is
`notes.lua`.

## Loading

- `plugin/annotate.lua` is the only module read at startup. It registers
  `:Annotate`, running the implementation through `pcall` (reporting a raised
  error with `vim.notify`), and delegates completion to `util/usercmd` (the
  argument splitter and completion dispatcher, which knows nothing about the
  subcommands).
- Its run / completion callbacks are `require("annotate").run` / `.complete`
  behind a `require` performed at call time, so `init.lua` and the modules it
  pulls in are read on the first `:Annotate` (or first `<Tab>`), not before.
- Registration belongs to `plugin/`, which every loading path reaches,
  including `packadd!` during startup, whose bang only suppresses sourcing at
  that moment. A `packadd!` issued *after* startup never sources `plugin/`;
  use plain `packadd` there.

`setup()`:

- exists only to change a default; nothing requires it, and it registers
  nothing.
- is the one call that can arrive *after* the notes are on screen, since
  opening a file is enough to draw them, so it ends in `notes.refresh()` to
  redraw them under the new configuration.
- reaches for that only when `annotate.notes` is already in `package.loaded`,
  so a `setup()` in an otherwise untouched session does not pull the feature
  modules in by itself.

The one thing that cannot be lazy is a note appearing in a file the user opens
without asking for anything:

- `plugin/` registers a single `once = true` `BufReadPost` autocommand, which
  requires `annotate.notes` and loads it.
- From then on `util/extmarks` has its own `BufReadPost` and the bootstrap one
  is spent.
- The buffer that triggered it is covered by the sweep over already-loaded
  buffers that `define_group` performs, because `util/extmarks` installs its
  autocommand *during* that same event and Neovim does not run autocommands
  added mid-event.

## Notes are extmarks, but not only extmarks

A note has to survive what an extmark does not: it is restored from disk before
anything is open, it outlives the buffer being unloaded, and it must come back
on the right line when the file is opened again, while in between tracking the
user's edits, which is exactly what an extmark is for and a stored line number
is not.

`util/extmarks.lua` is that pairing. A group keeps `file -> id -> mark` as the
durable copy and mirrors it into whichever buffers happen to be loaded, so
positions have two sources:

| state | authority |
| --- | --- |
| file loaded in a buffer | the buffer, whose extmark has been tracking edits |
| not loaded | the group's own table |

- The reads taking a `live` flag (`get_extmark_by_location`, `get_extmarks`,
  `get_file_extmarks`) go to `nvim_buf_get_extmarks` when there is a buffer and
  report what it says. `notes.lua` passes `live = true` everywhere, so nothing
  else has to think about which of the two is current.
- `BufWritePost` and `BufUnload` fold the drift back into the table even for
  notes nobody read, which is what makes a note written to the store name the
  line the user just saved.
- `sync(bufnr)` exposes that fold as a call, and `notes`' own `BufWritePost`
  makes it before saving, so the save naming the just-saved line follows from
  what `notes` does rather than from the order two augroups were registered in.
- Placement is clamped to the buffer's line count: a file can have been
  shortened outside the editor since its notes were written, and a stale line
  number should be a note at the end rather than an error.
- The module is generic and self-contained: it holds no plugin name of its own,
  and `M.init(prefix)` claims one. Namespaces and augroups are process-wide and
  keyed by name while the group table is per module instance, so two copies of
  this file asking for the same group name would otherwise share a namespace
  and clear each other's autocommands. That is also why `M.define_group` hands
  back a table of closures over one group rather than a shared module-level
  API.
- `define_group` sweeps the already-loaded buffers, which is what draws the
  notes in the buffer whose `BufReadPost` bootstrapped the plugin: the module's
  own `BufReadPost` is registered during that same event and so does not run
  for it. `notes.attach()` therefore only has to load.
- Drawing options (virtual text, highlight, priority) live on the mark, not on
  the group, so `notes.refresh()` rebuilds the marks instead of calling the
  group's `refresh()`, which would redraw the existing ones under the
  configuration they were created with.

## Storage

`store.lua` writes one JSON file, `stdpath("data")/annotate.json` by default,
holding the notes as a map from file to the notes on it. There is one store in
force for the whole session, and no project inside it: the notes of every
project you annotate sit in the same file, keyed by absolute path.

`storage_file` moves it, and two things about that are refusals rather than
features:

- It is not called. It used to be a function, which is what made a store per
  project possible; the path it returned was re-decided against the current
  directory, so a write after that re-decision merged one project's notes into
  another's. A string cannot re-decide, so nothing here depends on noticing a
  directory change.
- A relative path is refused for the same reason at smaller scale: `io.open`
  resolves it against the process cwd, so one session would read and write two
  different files after a `:lcd` with nothing else changing. Both are reported
  once through `vim.notify`, and left in `M.complaint` for
  `:checkhealth annotate` to report again where the user is looking.

`store.path()` is the file the session is holding, resolved on first use:
`storage_file` when that is an absolute path, the default otherwise. Holding it
is what keeps a read and the writes merging against it from being about two
different files. `store.load()` clears it along with the baseline, since a read
is what re-establishes both.

Format and durability:

- Notes are written at the paths they were stored under, which in a global
  store is absolute for all of them: `_relative` only shortens a path under the
  store's directory, and no project is. A store deliberately placed inside a
  project still shortens its own project's paths, and still survives that
  project being moved. Shortening and reading it back cost nothing to keep, and
  version-1 migration needs `_absolute` either way.
- A version-1 store (the notes of every project in one file, bucketed by
  project root) is flattened on read: the roots are absolute, so each bucket
  becomes notes on absolute paths, and the next write is in the new format.
- Writes go to `<store>.tmp` and are renamed over the store, so a store that
  exists is always complete: a process going away mid-write would otherwise
  leave a truncated file.
- Clearing the last note removes the store rather than leaving an empty one.
  `_merge` keeps another session's notes, so the branch that does it is only
  reached when there is nothing on disk to lose.
- A missing store is a store with no notes yet. An unreadable or malformed one
  is reported and treated the same way: a corrupt file costs the session its
  notes, never its startup.
- Saving is `BufWritePost` plus a save on every mutation, never on exit. A
  `VimLeavePre` save was tried and removed: it recorded the read-time clamp
  (`_place_extmark`'s `math.min(lnum, line_count)`, for a file shortened
  outside the editor) and nothing else, because drift is written by
  `BufWritePost` and a buffer that was never written has no disk truth to
  record. Losing it is a fix: the clamp is recomputed on every load, so a note
  clamped while a file was momentarily truncated snaps back when the file
  regrows, instead of being pinned to the truncated line.

## UI

Everything the plugin asks the user goes through `vim.ui.*`:

- `vim.ui.input` for a note's text;
- `vim.ui.select` for picking one;
- `vim.ui.select` over yes/no, defaulting to no, for confirming a clear, since
  everything asked there destroys notes.

So the plugin has no picker of its own to maintain and inherits whichever one
the user has installed.

`ui.open` prefers a window in the current tab that already shows the file,
falls back to editing in the current window, and never opens into a floating
window, since a note picked from a float would otherwise replace the float's
own buffer.

## Help file

`doc/annotate.txt` is generated from `README.md`; edit the README, never the
help file.

```sh
scripts/gendoc.sh          # rewrites doc/annotate.txt and doc/tags
scripts/gendoc.sh --check  # exits 1 when the help file is stale
```

Generator: [panvimdoc](https://github.com/kdheepak/panvimdoc), pinned in
`scripts/gendoc.sh` to a commit, since a tag can be moved and a commit cannot,
so the same README always produces the same help file.

- Fetched into `$XDG_CACHE_HOME/panvimdoc-<commit>` on first run and reused.
- `PANVIMDOC_DIR` uses a checkout of your own.
- Only `pandoc` needs installing (`brew install pandoc`); nvim is used just to
  refresh `doc/tags`.

`doc/tags` is committed, as |package-create| recommends: nothing in the native
package path generates it, so shipping it is what makes `:help annotate` work
for someone dropping the repo into `pack/*/opt`. Plugin managers, `vim.pack`
included, delete and regenerate it on install and update.

Section names come from the README headings, and so do the tags. A heading may
end in a hidden comment naming the tag it wants, project name prefixed
automatically:

```markdown
## Configuration <!-- tag: configuration -->
```

The comment is invisible on GitHub. Every README section declares one, so
renaming a section never silently renames its help tag.

## Conventions

- User-visible messages go through a module-local `_notify` that prefixes
  `[annotate]`.
- Private functions are `_`-prefixed and file-local; the module table exports
  only entry points.
- Types are declared with LuaLS `---@class` / `---@field` annotations.
- Highlight groups are defined with `default = true` so a colorscheme wins, and
  redefined on `ColorScheme`, which clears them.
- Configuration is read at the point of use: `config.values` is mutated in
  place rather than replaced, so a module that captured it in a local at
  `require` time does not go on reading the pre-`setup()` table.

## History

Started as the notes half of `loop-marks.nvim`, an extension to
[loop.nvim](https://github.com/loop-nvim/loop.nvim). What loop.nvim supplied is
now the plugin's own:

- workspace persistence → `store.lua`;
- `loop.extmarks` → `util/extmarks.lua`, with one group instead of a registry;
- the workspace picker, floating input and confirmation → `vim.ui.select` /
  `vim.ui.input`.

The bookmarks half was dropped.
