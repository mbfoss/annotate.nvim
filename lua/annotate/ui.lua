local M = {}

local inputwin = require("annotate.util.inputwin")
local ui_util  = require("annotate.util.ui")

--- The small amount of UI the plugin needs, over the vendored `util/ui` and
--- `util/inputwin`.
---
--- It lives here rather than in `util/` because `util/` is vendored verbatim
--- from neotoolkit by `scripts/vendor-neotoolkit.sh` and re-syncing it
--- overwrites whatever is in there; what this plugin wants that neotoolkit
--- does not supply belongs on this side of that line.
---
--- Picking goes through `vim.ui.*`, so it looks like everything else in the
--- user's editor and a `dressing`/`snacks`/`fzf` style replacement is picked
--- up without this plugin knowing about it. Entering a note does not: it is
--- written in a float at the cursor -- see `util/inputwin` -- because a note
--- belongs next to the line it annotates.

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

--- Show `file` at `lnum`.
---
--- `util/ui.smart_open_file` does the window choosing: a window in the current
--- tab already showing the file is reused, otherwise an ordinary window of the
--- tab is -- never a float or a `winfixbuf` panel, which a note picked from a
--- picker would otherwise replace the buffer of.
---
--- What it does not do is make the line worth arriving at, so a jump ends by
--- opening any fold over the note and centring it.
---@param file string
---@param lnum integer?
function M.open(file, lnum)
    local winid = ui_util.smart_open_file(file, lnum, 0, true)
    if winid < 0 then return end

    if lnum then
        vim.api.nvim_win_call(winid, function() vim.cmd("normal! zvzz") end)
    end
end

--- Ask for a line of text. `default` prefills the prompt, which is what makes
--- setting a note over an existing one an edit rather than a retype.
---
--- This one is not `vim.ui.input`: a note is written where it will be read,
--- next to the line it is attached to, and the window grows with the text
--- instead of holding it in a one-line cmdline prompt.
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

--- Ask a yes/no question, defaulting to no: everything asked here destroys
--- notes, so the answer that costs nothing is the one <CR> gives.
---
--- `util/ui.confirm_action` would do this too, but through `vim.fn.confirm`;
--- going through `vim.ui.select` keeps every question this plugin asks in the
--- user's own picker.
---@param msg string
---@param on_confirm fun(confirmed:boolean)
function M.confirm(msg, on_confirm)
    vim.ui.select({ "no", "yes" }, { prompt = msg .. "?" }, function(choice)
        on_confirm(choice == "yes")
    end)
end

return M
