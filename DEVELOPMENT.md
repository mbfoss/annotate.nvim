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
    extmarks.lua                extmarks keyed by file rather than by buffer
    ui.lua                      cursor location, prompting, jumping to a note
    usercmd.lua                 argument splitting + subcommand completion
```

`init.lua` owns only argument parsing and completion; the feature is
`notes.lua`.

## Loading

- `plugin/annotate.lua` is the only module read at startup. It registers
  `:Annotate` through `util/usercmd` (the argument splitter and completion
  dispatcher, which knows nothing about the subcommands).
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
holding the notes as a map from file to the notes on it. There is no project
inside the store: it holds whatever the session hands it, and a store per
project is a `storage_file` returning a path inside the project.

`storage_file` may be a function, so the path can depend on something not known
at `setup()` time: the current directory, which is what a per-project store
keys off:

- `store.resolve()` calls it.
- `store.path()` is the answer the session is holding, taken at the read and
  kept until the next one: a session that read one store and then wrote another
  would merge against a baseline that never described that file's notes, and
  would drop them.
- The function returns a path or nothing: anything that is not a string falls
  back to `config.default_storage_file()`, so it only has to answer for the
  directories it wants kept elsewhere, and a nil out of a `vim.fs.root()` that
  found no project is not an error.

Following the current directory is a re-read, not a different write target:

- `notes.reload()`, on `DirChanged`, compares `store.resolve()` with
  `store.path()` and, where they differ, saves the notes to the store they came
  from, drops every mark, and draws the new store instead.
- Nothing is carried across: a note belongs to the store it was read from, and
  keeping it would copy it into the next one at the first save.
- Where the two agree (a single store for every project, the default), the
  notes are left alone.
- `store.load()` clears the held path along with the baseline, which is what
  lets that re-read resolve the store again.

Format and durability:

- Notes are stored relative to the store's directory when they are under it,
  absolute when not (a header read out of `/usr/include`, or every note in the
  default store under `stdpath("data")`). A store kept inside a project
  therefore survives that project being moved or cloned elsewhere.
- A version-1 store (the notes of every project in one file, bucketed by
  project root) is flattened on read: the roots are absolute, so each bucket
  becomes notes on absolute paths, and the next write is in the new format.
- Writes go to `<store>.tmp` and are renamed over the store, so a store that
  exists is always complete: saving happens on `VimLeavePre` among other
  places, where a process going away mid-write would otherwise leave a
  truncated file.
- Clearing the last note removes the store rather than leaving an empty one.
- A missing store is a store with no notes yet. An unreadable or malformed one
  is reported and treated the same way: a corrupt file costs the session its
  notes, never its startup.

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
