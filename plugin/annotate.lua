if vim.fn.has("nvim-0.10") ~= 1 then
    error("annotate.nvim requires Neovim >= 0.10")
end

-- `:Annotate` is registered here at startup without requiring any Lua: both
-- callbacks pull in what they need on first use. `util/usercmd` is the command
-- plumbing -- it splits the arguments and drives completion, and knows nothing
-- about what the subcommands do -- and `annotate` is the plugin proper.
-- Neither is read until the command is first run or completed.
-- Both modules are cached in a local on first use, so the callbacks pay for a
-- `require` lookup once rather than on every invocation.
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

-- Notes have to appear in a file the user opens without asking for them, which
-- is the one thing the command cannot be lazy about. The first file read pulls
-- the plugin in and draws its notes; from then on `annotate.util.fileextmarks`
-- has its own `BufReadPost` and this one is done. That autocommand is created
-- while this event is still being processed, and Neovim does not run
-- autocommands added mid-event, so the buffer that triggered this is covered
-- instead by the sweep over already-loaded buffers that defining the group
-- performs.
vim.api.nvim_create_autocmd("BufReadPost", {
    group = vim.api.nvim_create_augroup("annotate.bootstrap", { clear = true }),
    once = true,
    callback = function(ev)
        require("annotate.notes").attach(ev.buf)
    end,
})
