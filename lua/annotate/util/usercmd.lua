local M = {}

-- No argument parsing of its own: dispatch passes `opts.fargs` through and
-- completion re-parses the command line, so both split by Vim's rules.

---@alias annotate.util.usercmd.subcommand fun(cmd:string,rest:string[],arg_lead:string):string[]

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

return M
