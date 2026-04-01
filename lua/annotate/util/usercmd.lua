local M = {}

---@diagnostic disable-next-line: deprecated
local unpack = table.unpack or unpack

--- Command plumbing for a command registered with `nargs = "*"`: it splits the
--- arguments and drives completion, and knows nothing about what the
--- subcommands do. Both entry points are called from inside the command's own
--- callbacks, so this module -- and whatever the callbacks close over -- is
--- only read when the command is first used.

---@alias annotate.usercmd.subcommand_fn fun(cmd:string,rest:string[],arg_lead:string):string[]
---@alias annotate.usercmd.run_fn fun(cmd:string,args:string[],opts:vim.api.keyset.create_user_command.command_args)

---@param str string
---@return string[]
local function _split_args(str)
    return vim.split(vim.trim(str), "%s+", { trimempty = true })
end

--- Completion for the command line as it stands.
---@param arg_lead string
---@param cmd_line string
---@param subcommand_fn annotate.usercmd.subcommand_fn
---@return string[]
function M.complete(arg_lead, cmd_line, subcommand_fn)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if not vim.startswith(s, "_") and vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    local args = _split_args(cmd_line)
    -- A trailing space means the argument being completed is a new, empty one
    -- rather than the last word typed.
    if cmd_line:match("%s+$") then
        table.insert(args, " ")
    end

    local cmd = args[1]
    if #args <= 1 then
        return filter(subcommand_fn(cmd, {}, arg_lead))
    end

    local rest = { unpack(args, 2) }
    rest[#rest] = nil
    return filter(subcommand_fn(cmd, rest, arg_lead))
end

--- Body of the command: splits `opts.args` and hands them to `run_fn`,
--- reporting any error it raises as a notification rather than as a stack
--- trace.
---@param opts vim.api.keyset.create_user_command.command_args
---@param run_fn annotate.usercmd.run_fn
function M.handle(opts, run_fn)
    local cmd = opts.name
    local args = _split_args(opts.args)
    local ok, err = pcall(run_fn, cmd, args, opts)
    if not ok then
        vim.notify(
            "[annotate.nvim] " .. cmd .. " command error\n" .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

return M
