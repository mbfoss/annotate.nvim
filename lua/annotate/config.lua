local M = {}

--- Configuration for annotate.nvim.
---
--- Every option has a working default, so `setup()` is optional: the plugin
--- registers itself from `plugin/annotate.lua` and reads these values at the
--- point of use, not at load time. That is also why the values live in a table
--- this module keeps and mutates in place rather than being replaced -- a
--- module that captured `config.values` in a local at `require` time would
--- otherwise go on reading the pre-`setup` table.

---@class annotate.Config
---@field symbol string        prefix drawn before the note text
---@field priority integer     extmark priority for the virtual text
---@field hl string            highlight group for the virtual text
---@field virt_text_pos string extmark `virt_text_pos` ("eol", "right_align", ...)
---@field auto_save boolean    write the store after every change
---@field root fun():string    project root the notes are stored against
---@field storage_file string|fun():string  JSON file the notes of every project are
---                        written to, or a function returning it

---@return annotate.Config
local function _defaults()
    return {
        symbol        = "⚑",
        priority      = 50,
        hl            = "AnnotateNote",
        virt_text_pos = "eol",
        auto_save     = true,
        root          = nil, ---@diagnostic disable-line: assign-type-mismatch
        storage_file  = vim.fs.joinpath(vim.fn.stdpath("data"), "annotate.json"),
    }
end

--- The project the notes belong to: the work tree the current directory is in,
--- or the current directory itself when it is not in a repository. Notes are
--- stored per root, so the same file annotated from two projects (a worktree
--- and a checkout of it, say) keeps two sets.
---@return string
local _root_cache = {}

local function _default_root()
    local cwd = vim.fs.normalize(vim.uv.cwd() or ".")
    local cached = _root_cache[cwd]
    if cached then return cached end

    -- One `git` call per directory, remembered: the root is asked for on every
    -- note that is set or looked up, and the answer cannot change while the
    -- current directory stays put.
    local root = cwd
    local out = vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
    if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then
        root = vim.fs.normalize(out[1])
    end
    _root_cache[cwd] = root
    return root
end

---@type annotate.Config
M.values = _defaults()
M.values.root = _default_root

--- Merge `opts` into the configuration. Optional -- calling it is only needed
--- to change a default.
---@param opts annotate.Config?
function M.setup(opts)
    local merged = vim.tbl_deep_extend("force", M.values, opts or {})
    -- `tbl_deep_extend` returns a new table; the module keeps the identity of
    -- `M.values` so that anything already holding a reference sees the change.
    for k in pairs(M.values) do M.values[k] = nil end
    for k, v in pairs(merged) do M.values[k] = v end
end

return M
