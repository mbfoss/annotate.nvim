local M = {}

--- Configuration. Every option has a default, so `setup()` is optional, and
--- `M.values` is mutated in place so a captured reference sees the change.

---@class annotate.Config
---@field symbol string        prefix drawn before the note text
---@field priority integer     extmark priority for the virtual text
---@field sign string          sign placed in the gutter; "" for none
---@field virt_text_pos ""|"off"|"eol"|"right_align"  extmark `virt_text_pos`,
---                        or "off" (or "") for no virtual text
---@field storage_file string|fun():string?  JSON file the notes are written to,
---                        or a function returning it, called at the read and on
---                        every directory change; nil means the default store

--- The store used when nothing else is configured, and the fallback for a
--- `storage_file` function that returns nil.
---@return string
function M.default_storage_file()
    return vim.fs.joinpath(vim.fn.stdpath("data"), "annotate.json")
end

---@return annotate.Config
local function _defaults()
    return {
        symbol        = "⚑",
        priority      = 50,
        sign          = "", -- one or two cells in the gutter; "" draws none
        virt_text_pos = "eol",
        storage_file  = M.default_storage_file(),
    }
end

---@type annotate.Config
M.values = _defaults()

--- Neovim rejects a `sign_text` wider than two cells on every note, so one that
--- cannot be drawn is reported once and dropped.
---@param cfg annotate.Config
local function _check_sign(cfg)
    if type(cfg.sign) ~= "string" or vim.fn.strdisplaywidth(cfg.sign) > 2 then
        vim.notify(
            ("[annotate] sign must be one or two cells wide, ignoring %s"):format(vim.inspect(cfg.sign)),
            vim.log.levels.WARN)
        cfg.sign = ""
    end
end

--- Merge `opts` into the configuration. Only needed to change a default.
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
