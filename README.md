# annotate.nvim

Line-anchored notes for Neovim, under a single `:Annotate` command.
A note is displayed as virtual text at the end of its line, follows the line as
the file is edited.

<img width="821" height="381" alt="image" src="https://github.com/user-attachments/assets/36520892-07e4-453d-bf07-657adef14516" />


| command | description |
| --- | --- |
| `Annotate [set]` | add or edit the note on the current line |
| `Annotate delete` | remove the note on the current line |
| `Annotate list` | select a note and jump to it |
| `Annotate qflist` | send every note to the quickfix list |
| `Annotate clear_file` | remove every note in the current file |
| `Annotate clear_all` | remove every note in the store |

## Requirements <!-- tag: requirements -->

Neovim >= 0.10. No other dependencies.

## Installation <!-- tag: installation -->

With `vim.pack`, Neovim 0.12's built-in plugin manager:

```lua
vim.pack.add({ "https://github.com/mbfoss/annotate.nvim" })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "mbfoss/annotate.nvim" }
```

There is no required setup call: `:Annotate` is registered when the plugin
loads, and the plugin's modules are loaded on first use or when a file with
notes is opened.

## Notes <!-- tag: notes -->

`:Annotate` asks for the note text on the current line. If the line already has
a note, the prompt starts with the old text so you can edit it. Submit an empty
prompt to delete it.

Notes show as virtual text (default), as a sign in the gutter, or both.

Notes are extmarks, so they follow their line as you edit the file instead of
sticking to a line number; the note line number is saved when the buffer is
saved.

Deleting an annotated line does not delete the note. It moves to the line that
takes its place.

`:Annotate list` picks a note with `vim.ui.select` and jumps to it, so a
`vim.ui.select` override such as Telescope is worth having. `:Annotate qflist`
sends them all to the quickfix list, which is better for reading through notes
than for jumping to one.

## Storage <!-- tag: storage -->

Notes are stored in a single JSON file, `stdpath("data")/annotate.json` by
default.

```json
{
  "notes": {
    "/home/me/proj/lua/init.lua": [{ "lnum": 12, "text": "rewrite this" }]
  }
}
```

To keep notes per project, set `storage_file` to a function returning a path.
It is called when the notes are read and whenever the current directory
changes, so it can depend on that directory: change it and the notes of the
project you left are written out and replaced by the ones kept there.

```lua
require("annotate").setup({
    storage_file = function()
        local root = vim.fs.root(0, ".git")
        if not root then return nil end -- no repository: use the default store
        return vim.fs.joinpath(root, ".annotate.json")
    end,
})
```

That writes `.annotate.json` in the root of the current git repository, which
is then a file to commit or to add to `.gitignore`.

Paths are relative to the store's directory when they are under it, so a
project store survives the project being moved or cloned; a note on a file
outside it keeps its absolute path.

The store is read when the plugin loads, and read again when a directory
change points `storage_file` at a different file. It is written whenever a
note changes, when a buffer holding notes is saved, and on exit. A store with
no notes left in it is deleted.

Several Neovim sessions can share a store. Each write merges into what is on
disk: the notes this session added, edited or deleted win, and every other
note is left alone. Notes are identified by file and line, so if two sessions
annotate the same line, the one that writes last wins. `:Annotate clear_all`
is the exception -- it empties the store, other sessions' notes included.

There is no locking. Two writes landing in the same instant can still lose
one, but sessions saving seconds or minutes apart -- the normal case -- will
not.

## Configuration <!-- tag: configuration -->

`setup()` is optional and only needed to change a default.

```lua
require("annotate").setup({
    symbol        = "⚑",        -- drawn before the note text
    priority      = 50,         -- extmark priority of the virtual text
    sign          = "",         -- one or two cells in the gutter; "" draws none
    virt_text_pos = "eol",      -- or "right_align", or "off" ("") for none
    storage_file  = nil,        -- path, or a function returning one; defaults
                                -- to stdpath("data")/annotate.json
})
```

| option | type | description |
| --- | --- | --- |
| `symbol` | string | prefix drawn before the note text |
| `priority` | number | extmark priority for the virtual text |
| `sign` | string | sign placed in the gutter, one or two cells wide; `""` draws none |
| `virt_text_pos` | string | extmark `virt_text_pos`: `eol`, `right_align`, or `off` (or `""`) for no virtual text |
| `storage_file` | string or function | JSON file the notes are written to; a function is called when the notes are read and on every current-directory change, and may return nil for the default store |

## Highlights <!-- tag: highlights -->

| group | default | applies to |
| --- | --- | --- |
| `AnnotateNote` | `Todo` | the note's virtual text |
| `AnnotateSign` | `AnnotateNote` | the note's sign in the gutter |

## API <!-- tag: api -->

`require("annotate.notes")` exposes the functionality directly, for keymaps and
for use from other code.

```lua
local notes = require("annotate.notes")

notes.set(file, lnum, text)   -- add or replace the note on a line
notes.get(file, lnum)         -- its text, or nil
notes.remove(file, lnum)      -- remove it, returns whether there was one
notes.list()                  -- every note: { file, lnum, text }, ordered
notes.clear_file(file)
notes.clear_all()             -- empties the store, other sessions included

notes.set_at_cursor()         -- the functions the commands call
notes.delete_at_cursor()
notes.select()
notes.qflist()
notes.clear_current_file()
notes.clear_all_confirm()
```

```lua
vim.keymap.set("n", "<leader>na", require("annotate.notes").set_at_cursor)
vim.keymap.set("n", "<leader>nd", require("annotate.notes").delete_at_cursor)
vim.keymap.set("n", "<leader>nl", require("annotate.notes").select)
```

## License <!-- tag: license -->

MIT
