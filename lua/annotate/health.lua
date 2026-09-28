---@brief Health check for annotate.nvim - run with `:checkhealth annotate`.
---
---Reports the Neovim version, the command, the note store in force, and the
---options that differ from the defaults. `setup()` is optional, so the config is
---reported either way.

local M = {}

local health = vim.health

---Check the Neovim version against the plugin's minimum (see
---`plugin/annotate.lua`). Silent on a supported version: a health check is for
---what is wrong, not for what is unremarkable.
local function _check_requirements()
    if vim.fn.has("nvim-0.10") ~= 1 then
        health.start("annotate: requirements")
        health.error("annotate.nvim requires Neovim >= 0.10")
    end
end

---The command comes from `plugin/annotate.lua`, so it exists without a
---`setup()`; its absence means the plugin directory was not loaded.
local function _check_command()
    health.start("annotate: command")

    if vim.fn.exists(":Annotate") == 2 then
        health.ok(":Annotate is registered")
    else
        health.error(":Annotate is not registered", {
            "plugin/annotate.lua did not run; check the plugin is on the runtimepath",
        })
    end
end

---The file notes are read from and written to: one store, wherever
---`storage_file` points when that is usable, else the default.
local function _check_store()
    health.start("annotate: note store")

    local store  = require("annotate.store")
    local file   = store.path() -- what is in force, complaint included
    local exists = vim.uv.fs_stat(file) ~= nil

    health.info(("notes are stored in %s"):format(file))
    if store.complaint then
        health.error(store.complaint, { "Set `storage_file` to an absolute path" })
    end

    if exists then
        health.ok("the store exists")
    else
        health.info("the store does not exist yet; it is written on the first note")
    end

    local dir = vim.fs.dirname(file)
    if vim.uv.fs_stat(dir) == nil then
        health.warn(("its directory (%s) does not exist"):format(dir), {
            "Create it, or point `storage_file` somewhere that exists",
        })
    end
end

---Collect the options whose value differs from the default, as flat paths with
---the value now in force. Lists are compared whole rather than descended into:
---a list-valued option is one option, not one option per element.
---@param current table
---@param defaults table
---@param prefix string  path of the enclosing table, "" at the top level
---@param out table[]
---@return table[]
local function _diff_config(current, defaults, prefix, out)
    for key, value in pairs(current) do
        local path = prefix .. tostring(key)
        local default = defaults[key]
        if type(value) == "table" and type(default) == "table" and not vim.islist(value) then
            _diff_config(value, default, path .. ".", out)
        elseif not vim.deep_equal(value, default) then
            table.insert(out, {
                path    = path,
                value   = vim.inspect(value, { newline = " ", indent = "" }),
                unknown = default == nil,
            })
        end
    end
    return out
end

---Report the options that differ from the defaults - the whole config would be
---mostly untouched defaults, and the point here is what this user changed.
---Anything set that the plugin does not define is flagged: `setup()` merges
---`opts` wholesale, so a misspelled option is kept silently.
local function _check_config()
    health.start("annotate: configuration")

    local config = require("annotate.config")
    local diffs  = _diff_config(config.current, config.defaults(), "", {})
    table.sort(diffs, function(a, b) return a.path < b.path end)

    if #diffs == 0 then
        health.ok("every option is at its default")
        return
    end

    local lines = {}
    for _, entry in ipairs(diffs) do
        table.insert(lines, ("  %s = %s"):format(entry.path, entry.value))
    end
    health.ok(("%d option%s differ%s from the defaults:\n%s")
        :format(#diffs, #diffs == 1 and "" or "s", #diffs == 1 and "s" or "",
            table.concat(lines, "\n")))

    for _, entry in ipairs(diffs) do
        if entry.unknown then
            health.warn(("`%s` is not an option annotate defines"):format(entry.path), {
                "Check its spelling against :help annotate-configuration",
            })
        end
    end
end

function M.check()
    _check_requirements()
    _check_command()
    _check_store()
    _check_config()
end

return M
