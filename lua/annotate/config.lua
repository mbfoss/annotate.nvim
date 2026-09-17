local M = {}

--- Configuration. Every option has a default, so `setup()` is optional.
---
--- Capture the live options once at a module's top
--- (`local config = require("annotate.config").current`) and read options off
--- that: `setup()` refills the table rather than replacing it, so the capture
--- stays current.

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

---The live options, at the defaults until `setup()` applies the user's. Always
---this same table: `setup()` refills it in place, so a captured reference --
---this table or any table under it -- never goes stale.
---@type annotate.Config
M.current = _defaults()

---The configuration as it shipped. A fresh table every call, so the caller may
---keep or mutate it.
---@return annotate.Config
function M.defaults()
    return _defaults()
end

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

--- Overwrite `dst` from `src` key by key: a key `src` lacks is dropped, and a
--- table on both sides recurses instead of being swapped in. Nothing reachable
--- from `current` is ever replaced, and nothing stale is left behind.
local function _refill(dst, src)
    for k in pairs(dst) do
        if src[k] == nil then dst[k] = nil end
    end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            _refill(dst[k], v)
        else
            dst[k] = v
        end
    end
end

--- Merge `opts` into the configuration. Only needed to change a default.
--- Merging over a fresh copy of the defaults rather than over `current` means
--- no key of an earlier call can survive into a later one.
---@param opts annotate.Config?
function M.setup(opts)
    local merged = vim.tbl_deep_extend("force", _defaults(), opts or {})
    _check_sign(merged)
    _refill(M.current, merged)
end

return M
