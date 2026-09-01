local M = {}

local config = require("annotate.config")

--- `:Annotate` -- notes attached to lines of your files.
---   Annotate [set]      add or edit the note on the current line
---   Annotate delete     remove the note on the current line
---   Annotate list       pick a note and jump to it
---   Annotate qflist     put every note in the quickfix list
---   Annotate clear_file remove every note in the current file
---   Annotate clear_all  remove every note in the store
---
--- This module owns only argument parsing and completion, as `M.run` and
--- `M.complete`; the command itself is registered in `plugin/annotate.lua`,
--- and the work lives in `annotate.notes`.

local _SUBCOMMANDS = { "set", "delete", "list", "qflist", "clear_file", "clear_all" }

---@return table
local function _notes()
    return require("annotate.notes")
end

--- Apply configuration. Optional: every option has a default and the command
--- registers itself without it. Notes already on screen are redrawn, so a
--- `setup()` that runs after the first file was opened still takes effect.
---@param opts annotate.Config?
function M.setup(opts)
    config.setup(opts)
    -- Only if the notes are already on screen: a `setup()` that runs before
    -- the first file is opened -- the ordinary case -- should not be what
    -- pulls the feature modules in.
    if package.loaded["annotate.notes"] then
        _notes().refresh()
    end
end

--- `:Annotate`'s implementation, as an `annotate.util.usercmd.run_fn`. Exposed
--- so that `plugin/annotate.lua` can register the command without this module
--- being loaded: it hands `util/usercmd` a wrapper that requires us on the
--- first invocation.
function M.run(_, args)
    local sub = args[1]
    local notes = _notes()

    if sub == nil or sub == "set" then
        notes.set_at_cursor()
    elseif sub == "delete" then
        notes.delete_at_cursor()
    elseif sub == "list" then
        notes.select()
    elseif sub == "qflist" then
        notes.qflist()
    elseif sub == "clear_file" then
        notes.clear_current_file()
    elseif sub == "clear_all" then
        notes.clear_all_confirm()
    else
        vim.notify(("[annotate] unknown subcommand: %s"):format(sub), vim.log.levels.ERROR)
    end
end

--- `:Annotate`'s completion, as an `annotate.util.usercmd.subcommand`. Exposed
--- for the same reason as `M.run`.
function M.complete(_, rest, _)
    if #rest == 0 then
        return vim.deepcopy(_SUBCOMMANDS)
    end
    return {}
end

return M
