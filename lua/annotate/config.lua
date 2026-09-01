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
---@field sign string          sign placed in the gutter; "" for none
---@field virt_text_pos ""|"off"|"eol"|"right_align"  extmark `virt_text_pos`,
---                        or "off" (or "") to draw no virtual text. A note sits
---                        at column 0, so the placements that need one
---                        ("inline", "overlay") have nothing to attach to.
---@field storage_file string|fun():string  JSON file the notes are written to,
---                        or a function returning it. A function is resolved at
---                        every read and write, so it can return a path that
---                        depends on the current directory or buffer -- which
---                        is how the notes are kept per project rather than in
---                        one store.

---@return annotate.Config
local function _defaults()
    return {
        symbol        = "⚑",
        priority      = 50,
        sign          = "", -- one or two cells in the gutter; "" draws none
        virt_text_pos = "eol",
        storage_file  = vim.fs.joinpath(vim.fn.stdpath("data"), "annotate.json"),
    }
end

---@type annotate.Config
M.values = _defaults()

--- Neovim rejects a `sign_text` that is not one or two cells wide, and it
--- would do so on every note rather than here, so a sign that cannot be drawn
--- is reported once and dropped.
---@param cfg annotate.Config
local function _check_sign(cfg)
    if type(cfg.sign) ~= "string" or vim.fn.strdisplaywidth(cfg.sign) > 2 then
        vim.notify(
            ("[annotate] sign must be one or two cells wide, ignoring %s"):format(vim.inspect(cfg.sign)),
            vim.log.levels.WARN)
        cfg.sign = ""
    end
end

--- Merge `opts` into the configuration. Optional -- calling it is only needed
--- to change a default.
---@param opts annotate.Config?
function M.setup(opts)
    local merged = vim.tbl_deep_extend("force", M.values, opts or {})
    _check_sign(merged)
    -- `tbl_deep_extend` returns a new table; the module keeps the identity of
    -- `M.values` so that anything already holding a reference sees the change.
    for k in pairs(M.values) do M.values[k] = nil end
    for k, v in pairs(merged) do M.values[k] = v end
end

return M
