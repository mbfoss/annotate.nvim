# annotate.nvim

Line-anchored notes for Neovim, under a single `:Annotate` command.

<img width="821" height="381" alt="image" src="https://github.com/user-attachments/assets/36520892-07e4-453d-bf07-657adef14516" />


A note is displayed as virtual text at the end of its line, follows the line as
the file is edited, and is stored outside the file itself. By default nothing is
written into the project.

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

`:Annotate` with no arguments, or `:Annotate set`, prompts for the text of a
note on the current line. On a line that already has a note, the existing text
is offered for editing; submitting an empty prompt removes the note.

A note can be displayed as virtual text at the end of its line, as a sign in
the gutter, or both. `sign` sets the sign character, and `""` disables it;
`virt_text_pos = "off"` disables the virtual text. With both disabled, a note
is invisible in the buffer but still appears in `:Annotate list` and
`:Annotate qflist`.

Notes are extmarks, so they track their line through inserts and deletes above
them instead of holding a fixed line number. Line numbers are recorded as they
stand when the file is written.

Deleting an annotated line does not discard the note. It moves to the line that
takes the deleted line's place, or to the last line of the file if the delete
extended to the end. The note remains visible and reachable from
`:Annotate list`, where it can be moved or removed with `:Annotate delete`.

`:Annotate list` opens `vim.ui.select` over every note in the store and jumps
to the selected one. `:Annotate qflist` sends the same list to the quickfix
window, which is more suitable for reading through notes than for jumping to a
single one.

`:Annotate delete` removes the note on the current line. `:Annotate clear_file`
and `:Annotate clear_all` remove every note in the current file or in the whole
store, after a confirmation.

## Storage <!-- tag: storage -->

Notes are stored in a single JSON file, `stdpath("data")/annotate.json` by
default, as a map from file to the notes on it:

```json
{
  "version": 2,
  "notes": {
    "/home/me/proj/lua/init.lua": [{ "lnum": 12, "text": "rewrite this" }]
  }
}
```

To keep notes per project, set `storage_file` to a function returning a path.
It is resolved at every read and write, so it can depend on the current buffer
or directory:

```lua
require("annotate").setup({
    storage_file = function()
        local root = vim.fs.root(0, ".git") or assert(vim.uv.cwd())
        return vim.fs.joinpath(root, ".annotate.json")
    end,
})
```

That writes `.annotate.json` in the root of the current git repository, which
is then a file to commit or to add to `.gitignore`. Paths are stored relative
to the directory the store is in when they are under it, so such a store
survives the project being moved or cloned elsewhere; a note on a file outside
that directory keeps its absolute path.

The store is written when a note changes, when a buffer holding notes is
written, and on exit. A store left with no notes is removed.

## Configuration <!-- tag: configuration -->

`setup()` is optional and only needed to change a default.

```lua
require("annotate").setup({
    symbol        = "⚑",        -- drawn before the note text
    priority      = 50,         -- extmark priority of the virtual text
    hl            = "AnnotateNote",
    sign          = "",         -- one or two cells in the gutter; "" draws none
    virt_text_pos = "eol",      -- or "right_align", or "off"
    auto_save     = true,       -- write the store as notes change
    storage_file  = nil,        -- path, or a function returning one; defaults
                                -- to stdpath("data")/annotate.json
})
```

| option | type | description |
| --- | --- | --- |
| `symbol` | string | prefix drawn before the note text |
| `priority` | number | extmark priority for the virtual text |
| `hl` | string | highlight group for the virtual text and the sign |
| `sign` | string | sign placed in the gutter, one or two cells wide; `""` draws none |
| `virt_text_pos` | string | extmark `virt_text_pos`: `eol`, `right_align`, or `off` for no virtual text |
| `auto_save` | boolean | when false, nothing is written unless `require("annotate.notes").save(true)` is called |
| `storage_file` | string or function | JSON file the notes are written to; a function is called at every read and write |

## Highlights <!-- tag: highlights -->

| group | default | applies to |
| --- | --- | --- |
| `AnnotateNote` | `Todo` | the note's virtual text and its sign |

Defined with `default = true`, so a colorscheme that sets this group takes
precedence.

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
notes.clear_all()
notes.save(true)              -- write the store even with auto_save = false

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
