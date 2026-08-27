local M = {}

--- The small amount of UI the plugin needs. Picking goes through `vim.ui.*`,
--- so it looks like everything else in the user's editor and a
--- `dressing`/`snacks`/`fzf` style replacement is picked up without this
--- plugin knowing about it. Entering a note does not: it is written in a float
--- at the cursor -- see `util/inputwin` -- because a note belongs next to the
--- line it annotates.

--- Whether `win` is an ordinary window in the layout rather than a floating
--- overlay (a completion popup, a notification, a picker).
---@param win integer
---@return boolean
local function _is_layout_win(win)
    return vim.api.nvim_win_get_config(win).relative == ""
end

--- Whether `bufnr` is a buffer holding a file the user is editing -- the only
--- kind of buffer a note can be attached to. A note is stored against a path,
--- so a scratch buffer, a terminal or a help page has nothing to attach to.
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

--- Show `file` at `lnum`. A window in the current tab already showing the file
--- is reused and jumped to; otherwise the file is edited in the current
--- window, or -- when the cursor is in a float -- in the first ordinary window
--- of the tab.
---@param file string
---@param lnum integer?
function M.open(file, lnum)
    local target = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))

    local win
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if _is_layout_win(w) then
            win = win or w
            local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
            if name ~= "" and vim.fs.normalize(name) == target then
                win = w
                break
            end
        end
    end
    if not win then return end

    vim.api.nvim_set_current_win(win)
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) ~= target then
        vim.cmd.edit(vim.fn.fnameescape(target))
    end

    if lnum then
        local last = vim.api.nvim_buf_line_count(0)
        vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(lnum, last)), 0 })
        vim.cmd("normal! zv")
        vim.cmd("normal! zz")
    end
end

--- Open a floating window on `buf` and keep an augroup alive alongside it.
---
--- The augroup is returned for the caller to hang the window's own autocommands
--- on, and is deleted when the window closes -- however it closes, including
--- ways the caller never hears about (`:quit`, a session being restored over
--- it) -- so a float that is gone never leaves autocommands behind. `on_close`
--- runs at the same point, for the caller to drop its handle to the window.
---@param buf integer
---@param enter boolean
---@param cfg vim.api.keyset.win_config
---@param on_close fun()?
---@return integer win
---@return integer augroup
function M.create_window(buf, enter, cfg, on_close)
    local win = vim.api.nvim_open_win(buf, enter, cfg)
    local augroup = vim.api.nvim_create_augroup(("annotate.win.%d"):format(win), { clear = true })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = augroup,
        pattern = tostring(win),
        once = true,
        callback = function()
            if on_close then on_close() end
            -- Deleting the group the callback is running in is why this is
            -- scheduled rather than done here.
            vim.schedule(function() pcall(vim.api.nvim_del_augroup_by_id, augroup) end)
        end,
    })

    return win, augroup
end

--- Ask for a line of text. `default` prefills the prompt, which is what makes
--- setting a note over an existing one an edit rather than a retype.
---
--- This one is not `vim.ui.input`: a note is written where it will be read,
--- next to the line it is attached to, and the window grows with the text
--- instead of holding it in a one-line cmdline prompt.
---@param prompt string
---@param default string?
---@param on_confirm fun(text:string?)
function M.input(prompt, default, on_confirm)
    require("annotate.util.inputwin").open({
        prompt = prompt,
        default = default,
    }, function(text)
        if text == nil then return end -- cancelled
        on_confirm(text)
    end)
end

--- Ask a yes/no question, defaulting to no: everything asked here destroys
--- notes, so the answer that costs nothing is the one <CR> gives.
---@param msg string
---@param on_confirm fun(confirmed:boolean)
function M.confirm(msg, on_confirm)
    vim.ui.select({ "no", "yes" }, { prompt = msg .. "?" }, function(choice)
        on_confirm(choice == "yes")
    end)
end

return M
