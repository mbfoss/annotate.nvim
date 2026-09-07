local M = {}

local config = require("annotate.config")

--- `:Annotate` -- argument parsing and completion only. The command is
--- registered in `plugin/annotate.lua`, and the work is in `annotate.notes`.

local _SUBCOMMANDS = { "set", "delete", "list", "qflist", "clear_file", "clear_all" }

---@return table
local function _notes()
    return require("annotate.notes")
end

--- Apply configuration. Optional, and notes already on screen are redrawn, so
--- a `setup()` after the first file was opened still takes effect.
---@param opts annotate.Config?
function M.setup(opts)
    config.setup(opts)
    -- Only if the notes are on screen: the ordinary `setup()`, before any file
    -- is opened, should not be what pulls the feature modules in.
    if package.loaded["annotate.notes"] then
        _notes().refresh()
    end
end

--- `:Annotate`'s implementation, as an `annotate.util.usercmd.run_fn`. Exposed
--- so the command can be registered without this module being loaded.
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
