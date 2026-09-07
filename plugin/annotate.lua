if vim.fn.has("nvim-0.10") ~= 1 then
    error("annotate.nvim requires Neovim >= 0.10")
end

-- `:Annotate` is registered without requiring any Lua: both callbacks pull in
-- what they need on first use, and cache it in these locals.
local usercmd ---@type table?
local annotate ---@type table?

---@return table
local function _usercmd()
    usercmd = usercmd or require("annotate.util.usercmd")
    return usercmd
end

---@return table
local function _annotate()
    annotate = annotate or require("annotate")
    return annotate
end

vim.api.nvim_create_user_command("Annotate", function(opts)
    _usercmd().handle(opts, function(cmd, args, cmd_opts)
        return _annotate().run(cmd, args, cmd_opts)
    end)
end, {
    nargs = "*",
    desc = "Notes attached to lines of your files",
    complete = function(arg_lead, cmd_line, _)
        return _usercmd().complete(arg_lead, cmd_line,
            function(cmd, rest, lead)
                return _annotate().complete(cmd, rest, lead)
            end)
    end,
})

-- Notes must appear in a file opened without asking for them, so the first read
-- pulls the plugin in; `util/fileextmarks` has its own `BufReadPost` after.
vim.api.nvim_create_autocmd("BufReadPost", {
    group = vim.api.nvim_create_augroup("annotate.bootstrap", { clear = true }),
    once = true,
    callback = function(ev)
        require("annotate.notes").attach(ev.buf)
    end,
})
