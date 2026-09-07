local M = {}

-- No argument parsing of its own: dispatch passes `opts.fargs` through and
-- completion re-parses the command line, so both split by Vim's rules.

---@alias annotate.util.usercmd.subcommand fun(cmd:string,rest:string[],arg_lead:string):string[]

---@alias annotate.util.usercmd.run_fn
---| fun(cmd:string,args:string[],opts:vim.api.keyset.create_user_command.command_args)


--- Completion for a command registered with `nargs = "*"`, called from inside
--- the `complete` callback so nothing is required until first used.
---@param arg_lead string
---@param cmd_line string
---@param subcommand annotate.util.usercmd.subcommand
---@return string[]
function M.complete(arg_lead, cmd_line, subcommand)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    -- nvim_parse_cmd splits exactly as <f-args> does, and strips any range or
    -- command modifiers. It throws on a command line it cannot parse.
    local ok, parsed = pcall(vim.api.nvim_parse_cmd, cmd_line, {})
    if not ok then return {} end

    -- Trailing whitespace means a new, still-empty argument has begun; without
    -- it the last argument is the one being completed, not context for it.
    local rest = parsed.args or {}
    if not cmd_line:match("%s$") then
        rest[#rest] = nil
    end

    return filter(subcommand(parsed.cmd, rest, arg_lead))
end

--- Body of a command registered with `nargs = "*"`: hands `fargs` to `run_fn`,
--- reporting any error as a notification rather than a stack trace.
---@param opts vim.api.keyset.create_user_command.command_args
---@param run_fn annotate.util.usercmd.run_fn
function M.handle(opts, run_fn)
    local cmd = opts.name
    -- nargs="*" always yields fargs; the fallback is only to satisfy its
    -- optional type.
    local ok, err = pcall(run_fn, cmd, opts.fargs or {}, opts)
    if not ok then
        vim.notify(
            "[annotate.util.nvim] " .. cmd .. " command error\n" .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

return M
