local M = {}

local inputwin = require("annotate.util.inputwin")
local ui_util  = require("annotate.util.ui")

--- The plugin's UI, over the generic `util/ui` and `util/inputwin`. Picking
--- goes through `vim.ui.*`; entering a note goes in a float at the cursor.

--- Whether `bufnr` holds a file being edited -- the only kind of buffer a note,
--- stored against a path, can attach to.
---@param bufnr integer
---@return boolean
function M.is_file_buf(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return false end
    if vim.bo[bufnr].buftype ~= "" then return false end
    return vim.api.nvim_buf_get_name(bufnr) ~= ""
end

--- The file and line under the cursor, as an absolute path and a 1-based line
--- number, or nil when the current buffer is not a file.
---@return string? file
---@return integer? lnum
function M.cursor_location()
    local bufnr = vim.api.nvim_get_current_buf()
    if not M.is_file_buf(bufnr) then return nil, nil end
    local file = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
    return file, vim.api.nvim_win_get_cursor(0)[1]
end

--- Show `file` at `lnum`. `smart_open_file` picks the window -- never a float
--- or `winfixbuf` panel -- and the jump ends by unfolding and centring.
---@param file string
---@param lnum integer?
function M.open(file, lnum)
    local winid = ui_util.smart_open_file(file, lnum, 0, true)
    if winid < 0 then return end

    if lnum then
        vim.api.nvim_win_call(winid, function() vim.cmd("normal! zvzz") end)
    end
end

--- Ask for a line of text, `default` prefilled so an existing note is edited.
--- Not `vim.ui.input`: a note is written next to the line it is attached to.
---@param prompt string
---@param default string?
---@param on_confirm fun(text:string)
function M.input(prompt, default, on_confirm)
    inputwin.open({
        prompt = prompt,
        default = default,
    }, function(text)
        if text == nil then return end -- cancelled
        on_confirm(text)
    end)
end

--- Ask a yes/no question, defaulting to no, since everything asked here
--- destroys notes. Through `vim.ui.select`, like every other prompt here.
---@param msg string
---@param on_confirm fun(confirmed:boolean)
function M.confirm(msg, on_confirm)
    vim.ui.select({ "no", "yes" }, { prompt = msg .. "?" }, function(choice)
        on_confirm(choice == "yes")
    end)
end

return M
